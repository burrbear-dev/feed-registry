// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Script.sol";
import "../src/FeedRegistry.sol";
import "../src/Proxy.sol";

contract DeployFeedRegistry is Script {
    function run(address _proxyAdminOwner) external {
        address deployerAddress = msg.sender;
        vm.startBroadcast();

        // 1. Deploy the implementation contract
        FeedRegistry implementation = new FeedRegistry();

        // 2. Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            FeedRegistry.initialize.selector,
            deployerAddress // initialOwner of FeedRegistry
        );

        // 4. Deploy the proxy
        Proxy proxy = new Proxy(
            address(implementation),
            _proxyAdminOwner,
            initData
        );

        // The proxy address is what users will interact with
        console.log("ProxyAdminOwner is:", _proxyAdminOwner);
        console.log("ProxyAdminOwner is:", _proxyAdminOwner);
        console.log("FeedRegistry Proxy deployed to:", address(proxy));
        console.log(
            "FeedRegistry Implementation deployed to:",
            address(implementation)
        );

        vm.stopBroadcast();
    }
}
