// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Script.sol";
import "../src/FeedRegistry.sol";
import "../src/Proxy.sol";

contract DeployFeedRegistry is Script {
    /// --- BARTIO --- ///
    /// TOKENS
    address private constant BARTIO_HONEY =
        0x0E4aaF1351de4c0264C5c7056Ef3777b41BD8e03;
    address private constant BARTIO_NECT =
        0xf5AFCF50006944d17226978e594D4D25f4f92B40;
    address private constant BARTIO_STGUSDC =
        0xd6D83aF58a19Cd14eF3CF6fe848C9A4d21e5727c;
    address private constant BARTIO_HETH =
        0x501Dbf23C2b004D751496ADC073dA3727c5Fe80f;
    address private constant BARTIO_HSOL =
        0x482c38Cd33e79A3E3C1CcE792a72d41BaFFFd416;
    address private constant BARTIO_HTIA =
        0x3dB20AEfcd234465C981B87Da025711c91aDD2C3;
    /// FXPPOOL DEPLOYERS
    address private constant BARTIO_FXPOOLDEPLOYER_HONEY =
        0x8E826703B6D471732415ABd4a1E724A3bF451511;
    address private constant BARTIO_FXPOOLDEPLOYER_NECT =
        0x33c608b9e7Ae1877dcb665Bd3d2D3bb327b01156;
    address private constant BARTIO_FXPOOLDEPLOYER_STGUSDC =
        0x8520b4Ed7E7e54343ADe583E6A7864718535eCa9;
    address private constant BARTIO_FXPOOLDEPLOYER_HETH =
        0x39da60365de955d03c6C1AB7b80e8a4c458FA87e;
    address private constant BARTIO_FXPOOLDEPLOYER_HSOL =
        0xb468a7AC04db7B07d8D2a8DeC3e6008397eC3E4D;
    address private constant BARTIO_FXPOOLDEPLOYER_HTIA =
        0xC3adc5347663C4fb93ad5029B6382a9f7fE73B05;

    /// --- BARTIO END --- ///

    function deployBartio(address _proxyAdminOwner) external {
        address registryOwner = msg.sender;

        vm.startBroadcast();

        FeedRegistry registry = _deployFeedRegistry(
            _proxyAdminOwner,
            registryOwner
        );
        IOwnable(BARTIO_FXPOOLDEPLOYER_HONEY).transferOwnership(
            address(registry)
        );
        IOwnable(BARTIO_FXPOOLDEPLOYER_NECT).transferOwnership(
            address(registry)
        );
        IOwnable(BARTIO_FXPOOLDEPLOYER_STGUSDC).transferOwnership(
            address(registry)
        );
        IOwnable(BARTIO_FXPOOLDEPLOYER_HETH).transferOwnership(
            address(registry)
        );
        IOwnable(BARTIO_FXPOOLDEPLOYER_HSOL).transferOwnership(
            address(registry)
        );
        IOwnable(BARTIO_FXPOOLDEPLOYER_HTIA).transferOwnership(
            address(registry)
        );

        registry.addDeployer(BARTIO_HONEY, BARTIO_FXPOOLDEPLOYER_HONEY);
        registry.addDeployer(BARTIO_NECT, BARTIO_FXPOOLDEPLOYER_NECT);
        registry.addDeployer(BARTIO_STGUSDC, BARTIO_FXPOOLDEPLOYER_STGUSDC);
        registry.addDeployer(BARTIO_HETH, BARTIO_FXPOOLDEPLOYER_HETH);
        registry.addDeployer(BARTIO_HSOL, BARTIO_FXPOOLDEPLOYER_HSOL);
        registry.addDeployer(BARTIO_HTIA, BARTIO_FXPOOLDEPLOYER_HTIA);

        vm.stopBroadcast();
    }

    function _deployFeedRegistry(
        address _proxyAdminOwner,
        address _registryOwner
    ) internal returns (FeedRegistry) {
        require(
            _proxyAdminOwner != address(0),
            "ProxyAdminOwner cannot be zero"
        );
        require(
            _registryOwner != _proxyAdminOwner,
            "RegistryOwner cannot be the same as ProxyAdminOwner"
        );

        // 1. Deploy the implementation contract
        FeedRegistry implementation = new FeedRegistry();

        // 2. Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            FeedRegistry.initialize.selector,
            _registryOwner // initialOwner of FeedRegistry
        );

        // 4. Deploy the proxy
        Proxy proxy = new Proxy(
            address(implementation),
            _proxyAdminOwner,
            initData
        );

        // The proxy address is what users will interact with
        console.log("FeedRegistry Proxy deployed to:\t", address(proxy));
        console.log("FeedRegistry Proxy admin is:\t\t", _proxyAdminOwner);
        console.log("FeedRegistry Owner is:\t\t\t", _registryOwner);

        // cast the proxy to FeedRegistry since we need to interact with it
        // rather than the implementation contract
        return FeedRegistry(address(proxy));
    }
}

interface IOwnable {
    function transferOwnership(address newOwner) external;
}
