// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/AggregatorV3Interface.sol";

/**
 * @title FeedRegistry
 * @notice A registry for Chainlink price feeds with associated ERC20 tokens and FXPoolDeployer integration
 */
contract FeedRegistry is AccessControlUpgradeable, OwnableUpgradeable {
    struct Feed {
        address deployerAddress;
        address feedAddress;
        bool isApproved;
        address[] associatedTokens;
    }

    // list of deployer addresses
    address[] private _deployers;
    // Mapping to store all feeds
    // deployer => baseFeed => Feed
    mapping(address => mapping(address => Feed)) private _feeds;
    // deployer => baseFeed[]
    mapping(address => Feed[]) private _feedsList;

    // Mapping to store pending feeds
    Feed[] public feedsPending;

    // map deployer to quote token
    mapping(address => address) public deployerToQuoteToken;
    // map quote token to deployer
    mapping(address => address) public quoteTokenToDeployer;

    event FeedApproved(address indexed quoteToken, address indexed baseFeed);
    event TokenAssociated(
        address indexed quoteToken,
        address indexed baseFeed,
        address indexed tokenAddress
    );
    event TokenRemoved(
        address indexed quoteToken,
        address indexed baseFeed,
        address indexed tokenAddress
    );
    event FeedPendingWithTokens(
        address indexed suggester,
        address indexed quoteToken,
        address indexed baseFeed,
        address[] tokens
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // see Initializable.sol: To prevent the implementation contract
        // from being used, you should invoke the {_disableInitializers} function
        // in the constructor to automatically lock it when it is deployed
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    function addDeployer(
        address quoteToken,
        address deployer
    ) external onlyOwner {
        _validToken(quoteToken);
        require(deployer != address(0), "Invalid deployer address");
        require(quoteToken != address(0), "Invalid quote token address");
        require(
            deployerToQuoteToken[deployer] == address(0),
            "Deployer already exists"
        );
        require(
            quoteTokenToDeployer[quoteToken] == address(0),
            "Quote token already exists"
        );
        require(
            IHasQuoteToken(deployer).quoteToken() == quoteToken,
            "Deployer.quoteToken() does not match quoteToken"
        );

        _deployers.push(deployer);
        deployerToQuoteToken[deployer] = quoteToken;
        quoteTokenToDeployer[quoteToken] = deployer;
    }

    function removeDeployer(address deployer) external onlyOwner {
        delete quoteTokenToDeployer[deployerToQuoteToken[deployer]];
        delete deployerToQuoteToken[deployer];
        uint256 len = _deployers.length;
        for (uint256 i = 0; i < len; i++) {
            if (_deployers[i] == deployer) {
                _deployers[i] = _deployers[len - 1];
                _deployers.pop();
                break;
            }
        }
    }

    /**
     * @notice Suggests a new feed to be added to the registry along with associated tokens
     * @param feedAddress The address of the Chainlink price feed
     * @param associatedTokens Array of ERC20 token addresses to associate with the feed
     */
    function suggestFeed(
        address quoteToken,
        address feedAddress,
        address[] calldata associatedTokens
    ) external {
        address deployer = quoteTokenToDeployer[quoteToken];
        require(deployer != address(0), "Deployer not found");
        _validFeed(feedAddress);
        require(
            _feeds[deployer][feedAddress].deployerAddress == address(0),
            "Feed already exists"
        );

        // Verify that the address implements AggregatorV3Interface
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddress);
        feed.latestRoundData(); // Will revert if not a valid feed

        // Verify all token addresses implement IERC20
        for (uint256 i = 0; i < associatedTokens.length; i++) {
            require(associatedTokens[i] != address(0), "Invalid token address");
            IERC20(associatedTokens[i]).totalSupply(); // Will revert if not a valid ERC20
        }

        // Store pending tokens
        feedsPending.push(
            Feed({
                feedAddress: feedAddress,
                deployerAddress: deployer,
                isApproved: false,
                associatedTokens: associatedTokens
            })
        );

        emit FeedPendingWithTokens(
            msg.sender,
            quoteToken,
            feedAddress,
            associatedTokens
        );
    }

    /**
     * @notice Approves a pending feed and its associated tokens
     * @param _pendingIndex The index of the feed to approve
     */
    function approveFeed(uint256 _pendingIndex) external onlyOwner {
        Feed memory pendingFeed = feedsPending[_pendingIndex];
        address baseFeed = pendingFeed.feedAddress;
        require(baseFeed != address(0), "Feed does not exist");
        pendingFeed.isApproved = true;

        address deployer = pendingFeed.deployerAddress;
        address quoteToken = deployerToQuoteToken[deployer];

        _feeds[deployer][baseFeed] = pendingFeed;
        _feedsList[deployer].push(pendingFeed);

        // call adminApproveBaseOracle on deployer
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("adminApproveBaseOracle(address)")),
            abi.encode(baseFeed)
        );
        _callDeployer(deployer, data);

        // Clean up pending tokens storage
        delete feedsPending[_pendingIndex];

        emit FeedApproved(quoteToken, baseFeed);
        uint256 len = pendingFeed.associatedTokens.length;
        for (uint256 i = 0; i < len; i++) {
            emit TokenAssociated(
                quoteToken,
                baseFeed,
                pendingFeed.associatedTokens[i]
            );
        }
    }

    function removeFeed(
        address quoteToken,
        address baseFeed
    ) external onlyOwner {
        address deployer = quoteTokenToDeployer[quoteToken];
        require(deployer != address(0), "Deployer not found");

        Feed memory feed = _feeds[deployer][baseFeed];
        require(feed.isApproved, "Feed not approved");
        delete _feeds[deployer][baseFeed];

        // call adminDisapproveBaseOracle on deployer
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("adminDisapproveBaseOracle(address)")),
            abi.encode(baseFeed)
        );
        _callDeployer(deployer, data);

        Feed[] storage feedList = _feedsList[deployer];
        uint256 len = feedList.length;
        for (uint256 i = 0; i < len; i++) {
            if (feedList[i].feedAddress == baseFeed) {
                feedList[i] = feedList[len - 1];
                feedList.pop();
                break;
            }
        }
    }

    /**
     * @notice Associates an ERC20 token with an approved feed
     * @param quoteToken The address of the quote token
     * @param baseFeed The address of the approved feed
     * @param tokenAddress The address of the ERC20 token
     */
    function associateToken(
        address quoteToken,
        address baseFeed,
        address tokenAddress
    ) external onlyOwner {
        _validToken(tokenAddress);
        address deployer = quoteTokenToDeployer[quoteToken];
        require(deployer != address(0), "Deployer not found");

        Feed memory feed = _feeds[deployer][baseFeed];
        require(feed.isApproved, "Feed not approved");
        require(tokenAddress != address(0), "Invalid token address");

        // Check if token is already associated
        address[] storage tokens = _feeds[deployer][baseFeed].associatedTokens;
        for (uint i = 0; i < tokens.length; i++) {
            require(tokens[i] != tokenAddress, "Token already associated");
        }

        tokens.push(tokenAddress);
        emit TokenAssociated(quoteToken, baseFeed, tokenAddress);
    }

    function removeToken(
        address quoteToken,
        address baseFeed,
        address tokenAddress
    ) external onlyOwner {
        address deployer = quoteTokenToDeployer[quoteToken];
        require(deployer != address(0), "Deployer not found");
        require(_feeds[deployer][baseFeed].isApproved, "Feed not approved");
        address[] storage tokens = _feeds[deployer][baseFeed].associatedTokens;
        for (uint i = 0; i < tokens.length; i++) {
            if (tokens[i] == tokenAddress) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }

        emit TokenRemoved(quoteToken, baseFeed, tokenAddress);
    }

    /**
     * @notice Allow owner to call functions on a deployer.
     * @dev This is useful for calling adminApproveBaseOracle and adminDisapproveBaseOracle
     * on the deployer contract but also for transferring ownership of the deployer
     * contract if ever needed.
     * @param deployer The address of the deployer
     * @param data The data to call the function with
     */
    function callDeployer(
        address deployer,
        bytes memory data
    ) external onlyOwner {
        _callDeployer(deployer, data);
    }

    /// @dev helper function to call a function on a deployer
    function _callDeployer(address deployer, bytes memory data) private {
        require(
            deployerToQuoteToken[deployer] != address(0),
            "Deployer not found"
        );

        (bool success, bytes memory returnData) = deployer.call(data);
        if (!success) {
            // If there is return data, try to extract and revert with the original error message
            if (returnData.length > 0) {
                // Look for revert reason and bubble it up if present
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            } else {
                revert("Call to deployer failed");
            }
        }
    }

    function _validFeed(address feedAddress) private view {
        require(feedAddress != address(0), "Invalid Feed");
        AggregatorV3Interface(feedAddress).latestRoundData();
    }

    function _validToken(address tokenAddress) private view {
        // NB: totalSupply >= 0 is a way to ensure that the token is valid by calling
        // the totalSupply function. We don't care if the supply is 0, as long as the function
        // doesn't revert.
        require(
            tokenAddress != address(0) &&
                IERC20(tokenAddress).totalSupply() >= 0,
            "Invalid token"
        );
    }

    function getDeployers() external view returns (address[] memory) {
        return _deployers;
    }

    function getFeeds(address deployer) external view returns (Feed[] memory) {
        return _feedsList[deployer];
    }

    function getFeedByQuoteToken(
        address quoteToken,
        address baseFeed
    ) external view returns (Feed memory) {
        address deployer = quoteTokenToDeployer[quoteToken];
        require(deployer != address(0), "Deployer not found");
        return _feeds[deployer][baseFeed];
    }

    function getFeedByDeployer(
        address deployer,
        address baseFeed
    ) external view returns (Feed memory) {
        return _feeds[deployer][baseFeed];
    }
    /**
     * @notice Returns all associated tokens for a feed
     * @param quoteToken The address of the quote token
     * @param baseFeed The address of the approved feed
     * @return tokens Array of associated token addresses
     */
    function getAssociatedTokens(
        address quoteToken,
        address baseFeed
    ) external view returns (address[] memory) {
        address deployer = quoteTokenToDeployer[quoteToken];
        require(deployer != address(0), "Deployer not found");
        require(
            _feeds[deployer][baseFeed].feedAddress != address(0),
            "Feed does not exist"
        );
        return _feeds[deployer][baseFeed].associatedTokens;
    }

    /**
     * @notice Checks if a feed is approved
     * @param quoteToken The address of the quote token
     * @param baseFeed The address of the approved feed
     * @return bool True if the feed is approved
     */
    function isFeedApproved(
        address quoteToken,
        address baseFeed
    ) external view returns (bool) {
        address deployer = quoteTokenToDeployer[quoteToken];
        require(deployer != address(0), "Deployer not found");
        return _feeds[deployer][baseFeed].isApproved;
    }
}

interface IHasQuoteToken {
    function quoteToken() external view returns (address);
}
