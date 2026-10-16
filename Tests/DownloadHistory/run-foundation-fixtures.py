from pathlib import Path
import sys

repository = Path(__file__).resolve().parents[2]
runner = repository / "scripts/test-download-history.py"
source = runner.read_text()
child = 'write("HistoryChild", "HistoryChild.swift", read("Tests/DownloadHistory/HistoryChild.swift"))'
package = '(scratch / "Package.swift").write_text'
assert source.count(child) == 1
assert source.count(package) == 1
source = source.replace(child, child + '''
write("EdithExtensionSupport", "HostStorageAccounting.swift", read("Packages/EdithHost/Sources/EdithHostCore/HostStorageAccounting.swift"))
write("EdithExtensionSupport", "FoundationBoundary.swift", "import Foundation\\nextension CocoaError.Code { static var validationMissingMandatoryProperty: Self { Self(rawValue: 1570) } }\\n")
''')
source = source.replace(package, '''(tests / "ActivityStorageTests.swift").write_text(read("Tests/DownloadHistory/ActivityStorageTests.swift"))
''' + package)
sys.argv[0] = str(runner)
exec(compile(source, str(runner), "exec"), {"__file__": str(runner), "__name__": "__main__"})
