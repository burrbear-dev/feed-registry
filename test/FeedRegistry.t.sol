// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "../src/FeedRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/interfaces/AggregatorV3Interface.sol";
import "../src/Proxy.sol";

interface IFXPoolDeployer {
    function quoteToken() external view returns (address);
    function adminApproveBaseOracle(address baseOracle) external;
    function adminDisapproveBaseOracle(address baseOracle) external;
}

// Mock ERC20 token for testing
contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
}

contract FeedRegistryV2 is FeedRegistry {
    function version() external pure override returns (string memory) {
        return "2.0.0";
    }
}

interface IOwnable {
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}

// Mock FXPoolDeployer for testing
contract MockFXPoolDeployer is IFXPoolDeployer, Ownable {
    address public quoteToken;

    address[] public approvedBaseOracles;

    constructor(address _quoteToken) Ownable(msg.sender) {
        quoteToken = _quoteToken;
    }

    function adminApproveBaseOracle(
        address baseOracle
    ) external override onlyOwner {
        approvedBaseOracles.push(baseOracle);
    }

    function adminDisapproveBaseOracle(
        address baseOracle
    ) external override onlyOwner {
        for (uint256 i = 0; i < approvedBaseOracles.length; i++) {
            if (approvedBaseOracles[i] == baseOracle) {
                approvedBaseOracles[i] = approvedBaseOracles[
                    approvedBaseOracles.length - 1
                ];
                approvedBaseOracles.pop();
            }
        }
    }
}

// Mock Chainlink Feed for testing
contract MockFeed is AggregatorV3Interface {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock Feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    )
        external
        pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, 1000e8, 1, 1, 1);
    }

    function latestRoundData()
        external
        pure
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, 1000e8, 1, 1, 1);
    }
}

contract FeedRegistryTest is Test {
    FeedRegistry public registry;
    address public proxyAdminOwner;
    Proxy public proxy;

    MockFeed public mockFeed;
    MockFeed public mockFeed2;
    IFXPoolDeployer public deployer;
    IFXPoolDeployer public deployer2;
    IERC20 public quoteToken;
    MockToken public token1;
    MockToken public token2;
    address public owner;
    address public user;

    function setUp() public virtual {
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
        mockFeed2 = new MockFeed();
        token1 = new MockToken("Token1", "TK1");
        token2 = new MockToken("Token2", "TK2");
        quoteToken = IERC20(address(new MockToken("QuoteToken", "QT")));

        MockFXPoolDeployer mockDeployer = new MockFXPoolDeployer(
            address(quoteToken)
        );
        MockFXPoolDeployer mockDeployer2 = new MockFXPoolDeployer(
            address(quoteToken)
        );
        // transfer ownership to registry
        IOwnable(address(mockDeployer)).transferOwnership(address(registry));
        IOwnable(address(mockDeployer2)).transferOwnership(address(registry));
        deployer = IFXPoolDeployer(address(mockDeployer));
        deployer2 = IFXPoolDeployer(address(mockDeployer2));
    }

    function testAddDeployer() public {
        registry.addDeployer(address(quoteToken), address(deployer));
        assertEq(
            registry.deployerToQuoteToken(address(deployer)),
            address(quoteToken),
            "Deployer to quote token mapping is incorrect"
        );
        assertEq(
            registry.quoteTokenToDeployer(address(quoteToken)),
            address(deployer),
            "Quote token to deployer mapping is incorrect"
        );
        assertEq(
            registry.getDeployers()[0],
            address(deployer),
            "Deployer not added"
        );
    }

    function testRemoveDeployer() public {
        registry.addDeployer(address(quoteToken), address(deployer));
        registry.removeDeployer(address(deployer));

        address[] memory _deployers = registry.getDeployers();
        assertEq(_deployers.length, 0, "Deployer list length is incorrect");

        assertEq(
            registry.deployerToQuoteToken(address(deployer)),
            address(0),
            "Deployer to quote token mapping is incorrect"
        );
        assertEq(
            registry.quoteTokenToDeployer(address(quoteToken)),
            address(0),
            "Quote token to deployer mapping is incorrect"
        );
    }

    function testCannotAddDuplicateDeployer() public {
        registry.addDeployer(address(quoteToken), address(deployer));
        vm.expectRevert("Deployer already exists");
        registry.addDeployer(address(quoteToken), address(deployer));
        vm.expectRevert("Quote token already exists");
        registry.addDeployer(address(quoteToken), address(deployer2));
    }

    function testSuggestApproveRemoveFeed() public {
        registry.addDeployer(address(quoteToken), address(deployer));

        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        vm.startPrank(user);
        vm.expectEmit(true, true, true, true);
        emit FeedRegistry.FeedPendingWithTokens(
            user,
            address(quoteToken),
            address(mockFeed),
            tokens
        );
        registry.suggestFeed(address(quoteToken), address(mockFeed), tokens);
        registry.suggestFeed(address(quoteToken), address(mockFeed2), tokens);
        vm.stopPrank();

        (, address feedAddress, bool isApproved) = registry.feedsPending(0);
        assertEq(feedAddress, address(mockFeed), "Feed is not pending");
        assertEq(isApproved, false, "Feed is approved");

        (, address feedAddress2, bool isApproved2) = registry.feedsPending(1);
        assertEq(feedAddress2, address(mockFeed2), "Feed2 is not pending");
        assertEq(isApproved2, false, "Feed2 is approved");

        // admin can approve feed
        vm.startPrank(owner);
        registry.approveFeed(0);
        vm.stopPrank();

        // feed2 is still pending
        (, feedAddress2, isApproved2) = registry.feedsPending(1);
        assertEq(feedAddress2, address(mockFeed2), "Feed2 is not pending");
        assertEq(isApproved2, false, "Feed2 is approved");

        // admin can approve feed2
        vm.startPrank(owner);
        registry.approveFeed(1);
        vm.stopPrank();

        assertEq(
            registry.isFeedApproved(address(quoteToken), address(mockFeed)),
            true,
            "Feed is not approved"
        );
        assertEq(
            registry.isFeedApproved(address(quoteToken), address(mockFeed2)),
            true,
            "Feed2 is not approved"
        );

        FeedRegistry.Feed memory feed = registry.getFeedByQuoteToken(
            address(quoteToken),
            address(mockFeed)
        );
        assertEq(
            feed.feedAddress,
            address(mockFeed),
            "[getFeedByQuoteToken] feed is not approved"
        );

        feed = registry.getFeedByDeployer(address(deployer), address(mockFeed));
        assertEq(
            feed.isApproved,
            true,
            "[getFeedByDeployer] feed is not approved"
        );

        // user cannot suggest feed again
        vm.startPrank(user);
        vm.expectRevert();
        registry.suggestFeed(address(quoteToken), address(mockFeed), tokens);
        vm.stopPrank();

        // admin can remove feed
        vm.startPrank(owner);
        registry.removeFeed(address(quoteToken), address(mockFeed));
        vm.stopPrank();

        assertEq(
            registry.isFeedApproved(address(quoteToken), address(mockFeed)),
            false,
            "Feed is approved"
        );
        vm.startPrank(owner);
        registry.removeFeed(address(quoteToken), address(mockFeed2));
        vm.stopPrank();

        assertEq(
            registry.isFeedApproved(address(quoteToken), address(mockFeed2)),
            false,
            "Feed2 is approved"
        );
    }

    function testCannotSuggestInvalidFeed() public {
        vm.startPrank(user);
        address[] memory tokens = new address[](0);
        vm.expectRevert();
        registry.suggestFeed(address(0), address(mockFeed), tokens);
        // dont allow suggesting a token as a feed
        vm.expectRevert();
        registry.suggestFeed(address(token1), address(mockFeed), tokens);
        vm.stopPrank();
    }

    function testCannotApproveNonexistentFeed() public {
        vm.expectRevert();
        registry.approveFeed(0);
    }

    function testAssociateRemoveToken() public {
        registry.addDeployer(address(quoteToken), address(deployer));

        // Suggest and approve a feed first
        address[] memory tokens = new address[](0);

        vm.prank(user);
        registry.suggestFeed(address(quoteToken), address(mockFeed), tokens);

        // cannot associate token to unapproved feed
        vm.expectRevert();
        registry.associateToken(
            address(quoteToken),
            address(mockFeed),
            address(token1)
        );

        registry.approveFeed(0);

        // Associate a new token
        vm.expectEmit(true, true, true, true);
        emit FeedRegistry.TokenAssociated(
            address(quoteToken),
            address(mockFeed),
            address(token1)
        );

        registry.associateToken(
            address(quoteToken),
            address(mockFeed),
            address(token1)
        );

        address[] memory associatedTokens = registry.getAssociatedTokens(
            address(quoteToken),
            address(mockFeed)
        );
        assertEq(associatedTokens.length, 1);
        assertEq(associatedTokens[0], address(token1));

        // cannot associate same token again
        vm.expectRevert();
        registry.associateToken(
            address(quoteToken),
            address(mockFeed),
            address(token1)
        );

        // can associate different token
        registry.associateToken(
            address(quoteToken),
            address(mockFeed),
            address(token2)
        );
        associatedTokens = registry.getAssociatedTokens(
            address(quoteToken),
            address(mockFeed)
        );
        assertEq(associatedTokens.length, 2);
        assertEq(associatedTokens[0], address(token1));
        assertEq(associatedTokens[1], address(token2));

        registry.removeToken(
            address(quoteToken),
            address(mockFeed),
            address(token1)
        );

        associatedTokens = registry.getAssociatedTokens(
            address(quoteToken),
            address(mockFeed)
        );
        assertEq(associatedTokens.length, 1);
        assertEq(associatedTokens[0], address(token2));
    }

    function testFEInterface() public {
        registry.addDeployer(address(quoteToken), address(deployer));

        // Suggest and approve a feed first
        address[] memory tokens = new address[](0);
        vm.startPrank(user);
        registry.suggestFeed(address(quoteToken), address(mockFeed), tokens);
        registry.suggestFeed(address(quoteToken), address(mockFeed2), tokens);
        vm.stopPrank();

        registry.approveFeed(1);
        registry.approveFeed(0);

        address[] memory deployers = registry.getDeployers();
        bool foundFeed = false;

        for (uint256 i = 0; i < deployers.length; i++) {
            FeedRegistry.Feed[] memory feeds = registry.getFeeds(deployers[i]);
            for (uint256 j = 0; j < feeds.length; j++) {
                if (feeds[j].feedAddress == address(mockFeed)) {
                    foundFeed = true;
                }
                assertEq(feeds[j].isApproved, true, "Feed is not approved");
            }
        }
        assertEq(foundFeed, true, "Feed is not found");
    }

    function testUpgradeWorks() public {
        // version before upgrade
        assertEq(registry.version(), "1.0.0");

        registry.addDeployer(address(quoteToken), address(deployer));
        // Suggest and approve a feed first
        address[] memory tokens = new address[](0);
        vm.prank(user);
        registry.suggestFeed(address(quoteToken), address(mockFeed), tokens);
        registry.approveFeed(0);
        // Deploy new implementation
        FeedRegistryV2 newImplementation = new FeedRegistryV2();

        // Upgrade proxy to new implementation and initialize it
        vm.startPrank(proxyAdminOwner);
        ProxyAdmin proxyAdmin = ProxyAdmin(proxy.getProxyAdmin());
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(newImplementation),
            // NB: do not call initialize again since the state has already been initialized
            bytes("")
        );
        vm.stopPrank();

        // version after upgrade
        assertEq(registry.version(), "2.0.0");

        // test that the state is preserved
        assertEq(
            registry.isFeedApproved(address(quoteToken), address(mockFeed)),
            true,
            "Feed is not approved after upgrade"
        );
        assertEq(
            registry
                .getFeedByQuoteToken(address(quoteToken), address(mockFeed))
                .feedAddress,
            address(mockFeed),
            "Feed is not approved after upgrade"
        );
    }
}
