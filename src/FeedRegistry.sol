// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin-contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin-contracts/token/ERC20/IERC20.sol";

import "amm-contracts/contracts/FXPoolDeployer.sol";


error FeedAlreadyExists();
error InvalidAddress();
error FeedDoesNotExist();
error CallToDeployerFailed();

/**
 * @title FeedRegistry
 * @notice A registry for Chainlink price feeds with associated ERC20 base tokens and FXPoolDeployer integration
 */
contract FeedRegistry is Ownable2StepUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
  

    address public feedRegistry;

    EnumerableSet.AddressSet private _deployers;

    EnumerableSet.AddressSet private _approvedFeeds;

    EnumerableSet.AddressSet private _pendingFeeds;

    mapping(address deployer =>  EnumerableSet.AddressSet baseFeed) internal _deployerFeeds ;
  
    mapping(address quoteToken=> address deployer) public quoteTokenToDeployer; 

    
     event FeedSuggested(
        address indexed suggester,        
        address indexed baseFeed
    );

     event FeedApproved(address indexed quoteToken, address indexed baseFeed);

    function __FeedRegistry_init(address _feedRegistry) internal onlyInitializing {
        __Ownable2Step_init();     
        feedRegistry = _feedRegistry;       
    }

     /**
     * @notice Suggests a new feed to be added to the registry 
     * @param baseFeed The address of the Chainlink price feed    
     */
    function suggestFeed(
        address baseFeed      
    ) external {        
        if (!_isFeedValid(baseFeed)) revert InvalidAddress(); 
        
        if (_approvedFeeds.contains(baseFeed)) revert FeedAlreadyExists();
                                   
        _pendingFeeds.add(baseFeed);             
                                                            
        emit FeedSuggested(msg.sender,  baseFeed);
    }

    /**
     * @notice Approves a pending feed 
     * @param baseFeed The address of the Chainlink price feed    
     * @param quoteToken The address of the quote token
     */
    function approveFeed(address baseFeed, address quoteToken) external onlyOwner {
        if(!_isTokenValid(quoteToken)) revert InvalidAddress(); 
        if (!_pendingFeeds.contains(baseFeed)) revert FeedDoesNotExist();

        address deployer = quoteTokenToDeployer[quoteToken];
       
        if(!_deployers.contains(deployer)){
            // deploy new fx pool deployer using proxy   
            // set deployer with new deployed address
            // update quoteTokenToDeployer[quoteToken]
            // add deployer to the list            
        }
        _pendingFeeds.remove(baseFeed);
        _approvedFeeds.add(baseFeed);

        _deployerFeeds[deployer].add(baseFeed);

        // call adminApproveBaseOracle on deployer
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("adminApproveBaseOracle(address)")),
            abi.encode(baseFeed)
        );
        _callDeployer(deployer, data);

       
        emit FeedApproved(quoteToken, baseFeed);
       
    }   

     /// @dev helper function to call a function on a deployer
    function _callDeployer(address deployer, bytes memory data) private {
       
        (bool success, bytes memory returnData) = deployer.call(data);
        if (!success) {
            // If there is return data, try to extract and revert with the original error message
            if (returnData.length > 0) {
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            } else {
                revert CallToDeployerFailed();
            }
        }
    }

    function _isTokenValid(address tokenAddress) private view returns (bool) {
        if (tokenAddress == address(0)) return false;
        try IERC20(tokenAddress).totalSupply() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function _isFeedValid(address feedAddress) private view  returns (bool) {
        if (feedAddress == address(0)) return false;
        return IFeedRegistry(feedRegistry).isFeedEnabled(feedAddress);        
    }
   
}

interface IFeedRegistry { 
    function isFeedEnabled(address aggregator) external view returns (bool);
}

