import os
from pathlib import Path


def isolated_test_environment(root, service):
    root = Path(root)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise ValueError('An existing private fixture directory is required.')
    if root.stat().st_uid != os.getuid() or root.resolve() in [Path('/'), Path.home()]:
        raise ValueError('The fixture directory must belong to the current user.')
    if not service.startswith('com.pulkit.edith.') or not any(
        marker in service for marker in ['.test.', '-test.', '.fixture.']
    ):
        raise ValueError('An isolated fixture service name is required.')
    private_home = root / 'home'
    if private_home.is_symlink() or (private_home.exists() and not private_home.is_dir()):
        raise ValueError('The private fixture home must be a regular directory.')
    private_home.mkdir(exist_ok=True)
    environment = dict(os.environ)
    environment.update(
        EDITH_DATA_ROOT=str(root / 'data'),
        EDITH_CLOUD_ROOT=str(root / 'cloud'),
        EDITH_DATABASE_HOME=str(private_home),
        EDITH_USAGE_SOURCE_HOME=str(private_home),
        EDITH_PROVIDER_KEYCHAIN_SERVICE=service + '.provider-credentials',
        EDITH_DATABASE_KEYCHAIN_SERVICE=service + '.keychain',
        EDITH_AGENT_MACH_SERVICE=service,
        EDITH_SHARED_DEFAULTS_SUITE=service + '.defaults',
        EDITH_HELPER_DEFAULTS_SUITE=service + '.helper',
    )
    return environment


def test_build_directory(repo):
    return Path(os.environ.get('EDITH_TEST_BUILD_DIR', Path(repo) / 'Packages/Edith/.build/debug')).resolve()
