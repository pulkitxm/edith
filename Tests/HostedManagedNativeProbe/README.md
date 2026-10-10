# Hosted managed native probe

This standalone manual probe tests public approval and the original Calendar
managed native view on a disposable GitHub-hosted arm64 macOS runner. It accepts
only the owned feature branch, an exact reviewed commit, and an authorized
dispatcher. No automatic event runs it and nothing publishes a release.

`make ci-hosted-managed-probe-check` runs pure native admission/control/proof
tests and typechecks both test entry points. It does not launch an application,
show a window, register a carrier, or change OS approval. Xcode
`build-for-testing` likewise only builds the standalone UI test runner.

The hosted build copies the current Host sources into a fresh scratch package
and adds one test-only public approval-browser entry under the existing fixture
compilation flag. Production Host files and admission guards remain unchanged.
The generated build receipt records both entry hashes. The same signed fixture
executable supplies the synthetic host, carrier and ExtensionKit worker. The
original scoped Calendar roles use the strict UUID synthetic backend.

XCTest selects a single exact Calendar toggle in the public browser. Missing,
duplicate, inaccessible or unknown-state controls fail. The initial state must
be disabled. Clicking the toggle is insufficient: the probe requires public
identity discovery for the exact UUID worker, followed by the existing managed
view smoke with authenticated readonly connection, fresh view generations,
last-close exit, both-role disable, released leases and zero owned processes.

The approval window is visible only on the disposable hosted runner. The
managed smoke uses an unshown window. Neither offscreen attachment nor public
approval proves visible original layout, keyboard behavior or feature parity.
This first probe stages a signed Calendar archive; it does not claim network
download, managed update/removal, all-provider coverage, or unchanged production
executable proof. Those require subsequent independent integration checks.

Direct dispatch requires registering the new manual workflow on the repository
default branch. Alternatively, an existing registered manual caller can invoke
this reusable workflow from the same reviewed feature ref, passing only the two
declared signing secrets and exact commit. The callee still refuses nonmanual
events and foreign refs or dispatchers. Feature code remains on the child branch;
workflow registration does not authorize merging the marketplace parent.
