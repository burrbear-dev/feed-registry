// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "../src/FeedRegistry.sol";
import "../src/interfaces/AggregatorV3Interface.sol";
import "../src/Proxy.sol";
import "./FeedRegistry.t.sol";

interface IHasBaseOraclesWhitelist {
    function baseOraclesWhitelist(
        address baseOracle
    ) external view returns (bool);
}

contract FeedRegistryIntegration is FeedRegistryTest {
    // --- bArtio constants ---
    uint256 private constant FORK_BLOCK_NO = 9270418;
    address private constant FXPOOL_DEPLOYER_USDC =
        0x8520b4Ed7E7e54343ADe583E6A7864718535eCa9;
    address private constant FXPOOL_DEPLOYER_NECT =
        0x33c608b9e7Ae1877dcb665Bd3d2D3bb327b01156;
    address private constant FXPOOL_DEPLOYER_HONEY =
        0x8E826703B6D471732415ABd4a1E724A3bF451511;

    function setUp() public override {
        vm.createSelectFork("https://bartio.rpc.berachain.com/", FORK_BLOCK_NO);

        owner = address(this);
        user = makeAddr("user");
        proxyAdminOwner = makeAddr("proxyAdminOwner");

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            FeedRegistry.initialize.selector,
            owner
        );

        // Deploy proxy
        proxy = new Proxy(
            address(new FeedRegistry()),
            proxyAdminOwner,
            initData
        );

        // Create interface to proxy
        registry = FeedRegistry(address(proxy));

        mockFeed = new MockFeed();
        token1 = new MockToken("Token1", "TK1");
        token2 = new MockToken("Token2", "TK2");
        quoteToken = IERC20(IFXPoolDeployer(FXPOOL_DEPLOYER_USDC).quoteToken());

        deployer = IFXPoolDeployer(FXPOOL_DEPLOYER_USDC);

        // transfer ownership to registry
        vm.startPrank(IOwnable(address(deployer)).owner());
        IOwnable(address(deployer)).transferOwnership(address(registry));
        vm.stopPrank();
    }

    function testMultipleDeployers() public {
        // transfer ownership for deployers
        vm.startPrank(IOwnable(address(FXPOOL_DEPLOYER_NECT)).owner());
        IOwnable(address(FXPOOL_DEPLOYER_NECT)).transferOwnership(
            address(registry)
        );
        vm.stopPrank();

        vm.startPrank(IOwnable(address(FXPOOL_DEPLOYER_HONEY)).owner());
        IOwnable(address(FXPOOL_DEPLOYER_HONEY)).transferOwnership(
            address(registry)
        );
        vm.stopPrank();

        // Add deployers
        registry.addDeployer(address(quoteToken), address(deployer));
        registry.addDeployer(
            address(IFXPoolDeployer(FXPOOL_DEPLOYER_NECT).quoteToken()),
            address(IFXPoolDeployer(FXPOOL_DEPLOYER_NECT))
        );
        registry.addDeployer(
            address(IFXPoolDeployer(FXPOOL_DEPLOYER_HONEY).quoteToken()),
            address(IFXPoolDeployer(FXPOOL_DEPLOYER_HONEY))
        );

        // Suggest feed to the USDC deployer
        registry.suggestFeed(
            address(quoteToken),
            address(mockFeed),
            new address[](0)
        );
        registry.approveFeed(0);
        assertTrue(
            IHasBaseOraclesWhitelist(address(deployer)).baseOraclesWhitelist(
                address(mockFeed)
            )
        );

        // Suggest feed to the NECT deployer
        registry.suggestFeed(
            address(IFXPoolDeployer(FXPOOL_DEPLOYER_NECT).quoteToken()),
            address(mockFeed),
            new address[](0)
        );
        registry.approveFeed(1);
        assertTrue(
            IHasBaseOraclesWhitelist(FXPOOL_DEPLOYER_NECT).baseOraclesWhitelist(
                address(mockFeed)
            )
        );
        registry.suggestFeed(
            address(IFXPoolDeployer(FXPOOL_DEPLOYER_HONEY).quoteToken()),
            address(mockFeed),
            new address[](0)
        );
        registry.approveFeed(2);
        assertTrue(
            IHasBaseOraclesWhitelist(FXPOOL_DEPLOYER_HONEY)
                .baseOraclesWhitelist(address(mockFeed))
        );
    }

    function testCanRecoverOwnership() public {
        vm.startPrank(IOwnable(address(deployer)).owner());
        IOwnable(address(deployer)).transferOwnership(address(registry));
        vm.stopPrank();

        registry.addDeployer(address(quoteToken), address(deployer));

        assertEq(
            IOwnable(address(deployer)).owner(),
            address(registry),
            "Owner is not registry"
        );

        bytes memory data = abi.encodeWithSelector(
            IOwnable(address(deployer)).transferOwnership.selector,
            address(this)
        );

        registry.callDeployer(address(deployer), data);

        assertEq(
            IOwnable(address(deployer)).owner(),
            address(this),
            "Owner is not this"
        );
    }
}
