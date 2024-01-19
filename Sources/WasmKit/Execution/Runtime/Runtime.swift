/// A container to manage execution state of one or more module instances.
public final class Runtime {
    public let store: Store
    let interceptor: RuntimeInterceptor?

    /// Initializes a new instant of a WebAssembly interpreter runtime.
    /// - Parameter hostModules: Host module names mapped to their corresponding ``HostModule`` definitions.
    public init(hostModules: [String: HostModule] = [:], interceptor: RuntimeInterceptor? = nil) {
        store = Store(hostModules)
        self.interceptor = interceptor
    }
}

public protocol RuntimeInterceptor {
    func onEnterFunction(_ address: FunctionAddress, store: Store)
    func onExitFunction(_ address: FunctionAddress, store: Store)
}

extension Runtime {
    public func instantiate(module: Module, name: String? = nil) throws -> ModuleInstance {
        let instance = try instantiate(module: module, externalValues: store.getExternalValues(module))

        if let name {
            store.namedModuleInstances[name] = instance
        }

        return instance
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#instantiation>
    func instantiate(module: Module, externalValues: [ExternalValue]) throws -> ModuleInstance {
        // Step 3 of instantiation algorithm, according to Wasm 2.0 spec.
        guard module.imports.count == externalValues.count else {
            throw InstantiationError.importsAndExternalValuesMismatch
        }

        // Step 4.
        let isValid = zip(module.imports, externalValues).map { i, e -> Bool in
            switch (i.descriptor, e) {
            case (.function, .function),
                (.table, .table),
                (.memory, .memory),
                (.global, .global):
                return true
            default: return false
            }
        }.reduce(true) { $0 && $1 }

        guard isValid else {
            throw InstantiationError.importsAndExternalValuesMismatch
        }

        // Steps 5-8.
        let initialGlobals = try evaluateGlobals(module: module, externalValues: externalValues)

        // Step 9.
        // Process `elem.init` evaluation during allocation

        // Step 11.
        let instance = store.allocate(
            module: module,
            externalValues: externalValues,
            initialGlobals: initialGlobals
        )

        // Step 12-13.
        var initExecution = ExecutionState()
        let frame = try initExecution.stack.pushFrame(arity: 0, module: instance, arguments: [], defaultLocals: [])

        // Steps 14-15.
        do {
            for (elementIndex, element) in module.elements.enumerated() {
                let elementIndex = UInt32(elementIndex)

                switch element.mode {
                case let .active(tableIndex, offsetExpression):
                    for i in offsetExpression.instructions + [
                        .numeric(.const(.i32(0))),
                        .numeric(.const(.i32(UInt32(element.initializer.count)))),
                        .table(.`init`(tableIndex, elementIndex)),
                        .table(.elementDrop(elementIndex)),
                    ] {
                        try initExecution.execute(i, runtime: self)
                    }

                case .declarative:
                    try initExecution.execute(.table(.elementDrop(elementIndex)), runtime: self)

                case .passive:
                    continue
                }
            }
        } catch Trap.undefinedElement, Trap.tableSizeOverflow, Trap.outOfBoundsTableAccess {
            throw InstantiationError.outOfBoundsTableAccess
        } catch {
            throw error
        }

        // Step 16.
        do {
            for case let (dataIndex, .active(data)) in module.data.enumerated() {
                assert(data.index == 0)

                for i in data.offset.instructions + [
                    .numeric(.const(.i32(0))),
                    .numeric(.const(.i32(UInt32(data.initializer.count)))),
                    .memory(.`init`(UInt32(dataIndex))),
                    .memory(.dataDrop(UInt32(dataIndex))),
                ] {
                    try initExecution.execute(i, runtime: self)
                }
            }
        } catch Trap.outOfBoundsMemoryAccess {
            throw InstantiationError.outOfBoundsMemoryAccess
        } catch {
            throw error
        }

        // Step 17.
        if let startIndex = module.start {
            try initExecution.invoke(functionAddress: instance.functionAddresses[Int(startIndex)], runtime: self)
            while initExecution.stack.currentLabel != nil || initExecution.stack.currentFrame != frame {
                try initExecution.step(runtime: self)
            }
        }

        // Steps 18-19.
        try initExecution.stack.popFrame()

        return instance
    }

    private func evaluateGlobals(module: Module, externalValues: [ExternalValue]) throws -> [Value] {
        let globalModuleInstance = ModuleInstance()

        for externalValue in externalValues {
            switch externalValue {
            case let .global(address):
                globalModuleInstance.globalAddresses.append(address)
            case let .function(address):
                globalModuleInstance.functionAddresses.append(address.address)
            default:
                continue
            }
        }

        globalModuleInstance.types = module.types

        for function in module.functions {
            let address = store.allocate(function: function, module: globalModuleInstance)
            globalModuleInstance.functionAddresses.append(address)
        }

        var initExecution = ExecutionState()
        try initExecution.stack.pushFrame(
            arity: 0, module: globalModuleInstance, arguments: [], defaultLocals: []
        )

        let globalInitializers = try module.globals.map { global in
            for i in global.initializer.instructions {
                try initExecution.execute(i, runtime: self)
            }

            return try initExecution.stack.popValue()
        }

        try initExecution.stack.popFrame()

        return globalInitializers
    }
}

extension Runtime {
    @available(*, unavailable, message: "Runtime doesn't manage execution state anymore. Use ExecutionState.step instead")
    public func step() throws {
        fatalError()
    }

    @available(*, unavailable, message: "Runtime doesn't manage execution state anymore. Use ExecutionState.step instead")
    public func run() throws {
        fatalError()
    }

    public func getGlobal(_ moduleInstance: ModuleInstance, globalName: String) throws -> Value {
        guard case let .global(address) = moduleInstance.exportInstances.first(where: { $0.name == globalName })?.value else {
            throw Trap._raw("no global export with name \(globalName) in a module instance \(moduleInstance)")
        }

        return store.globals[address].value
    }

    public func invoke(_ moduleInstance: ModuleInstance, function: String, with arguments: [Value] = []) throws -> [Value] {
        guard case let .function(function)? = moduleInstance.exports[function] else {
            throw Trap.exportedFunctionNotFound(moduleInstance, name: function)
        }
        return try function.invoke(arguments, runtime: self)
    }

    /// Invokes a function of the given address with the given parameters.
    public func invoke(_ address: FunctionAddress, with parameters: [Value] = []) throws -> [Value] {
        try Function(address: address).invoke(parameters, runtime: self)
    }
}
