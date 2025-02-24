// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/ProxyAdmin.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "amm-contracts/contracts/assimilators/BaseToUsdAssimilator.sol";
import "amm-contracts/contracts/assimilators/UsdcToUsdAssimilator.sol";

/**
 * @title FeedRegistry
 * @notice A registry for Chainlink price feeds with associated ERC20 base tokens and FXPoolDeployer integration
 */
contract FeedRegistry is OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    address public chainLnkFeedRegistry;

    EnumerableSet.AddressSet internal _deployers;

    EnumerableSet.AddressSet internal _approvedFeeds;

    EnumerableSet.AddressSet internal _pendingFeeds;
    // deployer => list of baseFeed
    mapping(address => EnumerableSet.AddressSet) internal _deployerFeeds;
    // quoteToken => deployer
    mapping(address => address) public quoteTokenToDeployer;

    event FeedSuggested(address indexed suggester, address indexed baseFeed);

    event FeedApproved(address indexed quoteToken, address indexed baseFeed);

    function __FeedRegistry_init(address _chainLnkFeedRegistry, address _fxPoolDeployerImpl) internal initializer {
        require(_chainLnkFeedRegistry != address(0) && _fxPoolDeployerImpl != address(0), "Invalid address");

        chainLnkFeedRegistry = _chainLnkFeedRegistry;
        fxPoolDeployerImpl = _fxPoolDeployerImpl;

        _upgrader = new ProxyAdmin(address(this));
        __Ownable_init();
    }

    function setFXPoolDeployerImplementation(address _fxPoolDeployerNewImpl) external onlyOwner {
        require(_fxPoolDeployerImpl != address(0) && _fxPoolDeployerNewImpl != fxPoolDeployerImpl, "Invalid address");

        fxPoolDeployerImpl = _fxPoolDeployerNewImpl;
    }

    /**
     * @notice Suggests a new feed to be added to the registry
     * @param baseFeed The address of the Chainlink price feed
     */
    function suggestFeed(address baseFeed) external {
        require(_isFeedValid(baseFeed), "Invalid address");

        require(!_approvedFeeds.contains(baseFeed), "Feed already exists");

        _pendingFeeds.add(baseFeed);

        emit FeedSuggested(msg.sender, baseFeed);
    }

    /**
     * @notice Approves a pending feed
     * @param baseFeed The address of the Chainlink price feed
     * @param quoteToken The address of the quote token
     * @param vault Balancer Vault address
     */
    function approveFeed(address baseFeed, address quoteToken, address vault) external onlyOwner {
        require(_isTokenValid(baseToken), "Invalid address");

        require(_isTokenValid(quoteToken), "Invalid address");

        require(_pendingFeeds.contains(baseFeed), "Feed does not exist");

        address _deployer = quoteTokenToDeployer[quoteToken];

        if (!_deployers.contains(_deployer)) {
            _deployer = _deployNewFXPoolDeployer(baseFeed, quoteToken, vault);

            _deployers.add(_deployer);

            quoteTokenToDeployer[quoteToken] = _deployer;
        }

        _pendingFeeds.remove(baseFeed);
        _approvedFeeds.add(baseFeed);

        _deployerFeeds[_deployer].add(baseFeed);

        // call adminApproveBaseOracle on deployer
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("adminApproveBaseOracle(address)")),
            abi.encode(baseFeed)
        );
        _callDeployer(_deployer, data);

        emit FeedApproved(quoteToken, baseFeed);
    }

    function _deployNewFXPoolDeployer(
        address baseFeed,
        address quoteToken,
        address vault
    ) internal returns (address _deployer) {
        BaseToUsdAssimilator _baseAssimilatorTemplate = new BaseToUsdAssimilator();

        UsdcToUsdAssimilator _quoteAssimilator = new UsdcToUsdAssimilator();

        _quoteAssimilator.initialize(baseFeed, quoteToken);

        // deploy a new proxy of fx pool deployer
        TransparentUpgradeableProxy _fxPoolDeployerProxy = new TransparentUpgradeableProxy(
            fxPoolDeployerImpl,
            address(_upgrader),
            ""
        );
        _deployer = address(_fxPoolDeployerProxy);
        // initialize  the proxy contract
        IFXPoolDeployer(_deployer).initialize(
            vault,
            quoteToken,
            address(_quoteAssimilator),
            address(_baseAssimilatorTemplate)
        );

        // call FXPoolDeployerTracker.broadcastNewDeployer()
    }

    /// @dev helper function to call a function on a deployer
    function _callDeployer(address deployer, bytes memory data) internal {
        (bool success, bytes memory returnData) = deployer.call(data);
        if (!success) {
            // If there is return data, try to extract and revert with the original error message
            if (returnData.length > 0) {
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            } else {
                revert("Call to deployer failed");
            }
        }
    }

    function _isTokenValid(address tokenAddress) internal view returns (bool) {
        if (tokenAddress == address(0)) return false;
        try IERC20(tokenAddress).totalSupply() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function _isFeedValid(address feedAddress) internal view returns (bool) {
        if (feedAddress == address(0)) return false;
        return IFeedRegistry(feedRegistry).isFeedEnabled(feedAddress);
    }
}

interface IFeedRegistry {
    function isFeedEnabled(address aggregator) external view returns (bool);
}

interface IFXPoolDeployer {
    function initialize(
        address _vault,
        address _quoteToken,
        address _quoteAssimilator,
        address _baseAssimilatorTemplate
    ) external;
}

interface FXPoolDeployerTracker {
    function broadcastNewDeployer(address _quoteToken, address _deployer) external returns (bytes32 key);
}
