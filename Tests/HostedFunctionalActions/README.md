# Hosted functional actions

This layer compiles the maintained original control sources into the owning native test target and connects them to the installed engine. Its receipts qualify that source control to engine delivery. They do not qualify traffic from the downloaded UI worker binary, which requires a separate installed presentation journey.

This layer adds successful original control actions to the existing owned worker lifecycle. Managed view-only receipts keep `functionalActionsValidated=false`. An action receipt is separate and requires independently signed producer observations.

Each owner has two maintained files:

- `scripts/hosted-functional-actions/cases/<id>.mjs` exports exactly `definition`.
- `Tests/HostedFunctionalActions/OwnerCases/<id>ActionCase.swift` implements `HostedFunctionalActionCase`.

The protocol also requires a fixed `static activationOperation`, matching the definition mutation operation.

The controls batch owns 20 IDs in `functionalActionBatches.controls`; the applications batch owns the remaining 19. Missing case files fail the all-owner loader. Keep Awake is the first wired example.

A definition declares the original control kind, label, mutation operation and exact original source hashes. It also declares the bounded IPC allowlist, independent observation kind/name, persistent record readback and synthetic limitations. Preparation rehashes the actual original control sources. The native action must issue the declared mutation, not merely read state.

The owning native test target compiles the original feature module. `assembleFunctionalCaseSources` copies the shared context, shared transport and one maintained owner case into a private target directory. It removes only the shared contract module import because those types become members of that copied test target. It does not modify original feature factories or controls. The compiler receipt records both original and copied source hashes. A target uses its actual original module with `@testable import`, as the maintained native tests do.

The host fixture starts its actual packaged worker through the existing lifecycle admission. The independent producer supplies a signed capability bound to source, session, UID, private paths, package version/hash, original case and current engine/UI PID/birth/executable identities. Its generation verifier must retain the fixture descriptor/root identities and independently verify current process identity, signature, ABI and source before and after each invocation. A shape-valid context alone is not admission. Cases receive neither the issuer key nor authority to choose another endpoint.

`HostedFunctionalActionTransport` derives the production `ExtensionPeerEndpoint` from the admitted private Commands directory. Cases use `invokeOriginal` in an original UI client's existing invocation callback, `makeEngineClient` for clients using the original engine bridge, and `readAuthoritative` for a separate checked read. Every operation is admitted by the capability. The transport records actual successful requests and replies only after its independent verifier succeeds.

The native driver entry point is:

```swift
let transport = try HostedFunctionalActionTransport(
    context: context,
    presentationID: presentationID,
    verifyCurrent: verifyCurrentGenerationAndHeldPins,
    observe: recordCheckedWorkerInvocation)
let result = try await HostedFunctionalActionNativeDriver.run(
    context: context,
    transport: transport,
    makeCase: { try KeepAwakeActionCase(transport: transport) })
```

The producer supplies both closures. They must inspect actual native ownership and preserve observed invocation bytes. They are not case callbacks returning a requested success. The driver checks ownership before constructing the case or accessing its defaults. After replacement and reinstall, it reads the original saved record before activation so a new action cannot repair lost data and hide the failure. It requires the original mutation acknowledgement, separate authoritative state, preserved readback and presentation shutdown.

Keep Awake creates the original `KeepAwakeSettings` view with the original `ControlPresentation`, presses its native accessibility checkbox and allows its existing change callback to send `keepAwake.ui.update` through the shared transport. It then separately reads the worker's `surface.snapshot` to verify its owned sleep assertion and `keepAwake.ui.read` to verify saved `preventSleep`. Its scoped backend is a synthetic assertion adapter, not a physical sleep policy measurement.

The producer holds the real worker lifecycle between initial activation, replacement and reinstallation so every phase can run its native action before the next transition. It observes exact old-generation absence, fresh engine/UI identities, physical removal of both captured versions, released leases and unchanged agentic sentinels. Natural final process/resource drain must precede cleanup. `validateFunctionalActionProof` compares the case's bounded claims to the separately signed producer observation, and rejects missing phases, stale identities, changed sources, readonly activation, failed acknowledgements and absent independent readback.

`synthetic-development` is explicitly limited to maintained 1.0.0/1.1.0 development fixture packages and claims no public update. `public-signed-pair` accepts an actual distinct lower/current version pair and requires its separate production public admission receipt, supplied through `admittedPublicPair` by the production public verifier. A producer-supplied receipt hash alone is rejected. The general context never invents a retained public version. Native hardware and the shipping privileged Lid Awake role remain separately unproved; an owned synthetic adapter cannot certify them.

Pure contract tests exercise only value validation, signatures and injected assembly. The native example is compiled locally without executing an application, controls, IPC, defaults or hardware. Actual action execution belongs exclusively to the isolated hosted Mac producer and its execution receipt. A successful contract test or native compile is not a successful hosted action.

The complementary installed presentation tier uses a maintained per-owner JSON recipe under `scripts/hosted-functional-actions/presentations`. Missing recipes fail closed. `installedPresentationUITestSource` generates a bounded XCTest that acts only on an already running host and an exact session/owner/phase window. It creates no substitute view and does not launch or terminate an application. Keep Awake uses the original downloaded checkbox, sets it off and then on, and requires the installed engine's actual `keepAwake.ui.update` acknowledgement and separate readback.

`validateInstalledPresentationObservation` requires the separately signed producer record, exact before/after source and downloaded bundle tree equality, all original factory/control hashes unchanged, verified host/worker/role signatures, retained root/descriptor pins, the exact presentation and engine/UI generation, an authenticated downloaded UI receiver mutation, independent authoritative output, and presentation/resource release. It rejects factory overlays and changed role payloads. The XCTest attachment is a bounded action claim that cannot qualify itself. Host phase holds, descriptor admission and producer observation still require the isolated hosted controller; generated source typechecking is compile proof only.
