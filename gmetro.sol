// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

pragma solidity 0.8.7;

// This contract is a simple semi-proxy staking contract. Its purpose is to hold GM owners metroverse blocks and stake them on the metroverse staking contract.
// This contract allows anyone to deposit and withdraw his blocks, and claim his earnings.
// By unstaking, you auto claim your earnings. You'll have to call the withdrawMET function in order to withdraw your funds from the contract.

contract GMetro is Ownable {
    event BlockReceived(address indexed owner, uint256 indexed tokenId,  address indexed to, uint256 timestamp);
    event BlockSent(address indexed owner, uint256 indexed tokenId, uint256 timestamp);

    struct Stake { // different from original Stake struct declaration in metroverse contracts to match with our needs
        address owner;
        uint40 timestamp;
        bool staked;
    }

    struct Account { // different from original Account struct declaration in metroverse contracts to match with our needs
        uint24 balance;
        uint256 metAllowance;
        uint[] tokenIds;
        mapping (uint => uint) AccountTokenIdToIndex;
    }
    
    mapping(uint256 => Stake) tokens;
    uint[] tokenIdsList;
    mapping (uint => uint) tokenIdToIndex;
    mapping(address => Account) accounts;
    address public tokenAddress = 0x1ffe8A8177D3C261600A8bD8080D424d64b7FBC2; // $MET address
    address public blockInfoAddress = 0xf69C9ff4AA4EA11C7CeE8C781E514E379Dbb18B5; 
    address public nftLookupAddress = 0xc81E0a00ba9feB8064C0323c6a8b75B5747c6D64;
    IVaultDoor vaultDoor = IVaultDoor(0xFbF753521714c267777b981F4f18Fa46056D0F91); // staking contract proxy
    
    constructor (){}

    function depositBlock (uint[] calldata _blockIds) external { // Note: Check ownership outside of the contract for gas purpose. Will revert if at least one of the blocks is not owned by the caller
        receiveBatch (msg.sender, _blockIds);
    }
    function withdrawBlock (uint256[] calldata tokenIds) external onlyBlockOwner(tokenIds){ // Allows msg.sender to withdraw the blocks he owns
        sendBatch(msg.sender, msg.sender, tokenIds);
    }
    function remove(address owner, uint tokenId) internal { // remove an address from the array
        uint index = accounts[owner].AccountTokenIdToIndex[tokenId]; // get the index of the tokenId in the personnal array
        for (uint i = index; i<(accounts[owner].tokenIds.length-1); i++){ // browse among all owner's blocks
                //shift the next blocks 
                accounts[owner].AccountTokenIdToIndex[accounts[owner].tokenIds[i+1]]--;
                accounts[owner].tokenIds[i] = accounts[owner].tokenIds[i+1];
                
        }
        uint globalIndex = tokenIdToIndex[tokenId]; // get the index of the tokenId in the global array
        for (uint i = globalIndex; i<(tokenIdsList.length-1); i++){ // browse among all blocks
                //shift the next blocks 
                tokenIdToIndex[tokenIdsList[globalIndex+1]]--;
                tokenIdsList[globalIndex] = tokenIdsList[globalIndex+1];
        }
        // delete the index linked to the removed tokenId 
        delete accounts[owner].AccountTokenIdToIndex[tokenId]; 
        delete tokenIdToIndex[tokenId]; 

        // delete the last block which is duplicated
        tokenIdsList.pop(); 
        accounts[owner].tokenIds.pop();
    }
    function withdrawMET () external { // Allows to withdraw you $MET allowed balance from this contract after claiming your earnings by unstaking or calling "claimMetOnStakedBlocks"
        require (accounts[msg.sender].balance >0, "empty balance");
        uint256 amount = accounts[msg.sender].balance;
        accounts[msg.sender].balance = 0;
        IERC20 token = IERC20(tokenAddress);
        token.transfer(msg.sender, amount);
    }

    function claimMetOnStakedBlocks (uint256[] calldata tokenIds) external onlyBlockOwner(tokenIds){ // Allows to claim $MET earnings without unstaking. The $MET is sent to this contract, you need to call withdrawMET in order to withdraw your claim
        IVaultDoor.EarningInfo memory earning = vaultDoor.earningInfo(tokenIds);
        accounts[msg.sender].metAllowance += earning.earned;
        vaultDoor.claim(tokenIds);
    }

    function stake (uint256[] calldata tokenIds) external onlyBlockOwner(tokenIds){ // Allows to stake deposited owned blocks on the metroverse staking contract
        for (uint i = 0; i < tokenIds.length; i++) tokens[tokenIds[i]].staked = true;
        vaultDoor.stake(tokenIds);
    }

    function unstake (uint256[] calldata tokenIds) external onlyBlockOwner(tokenIds){ // Allows to unstake owned blocks and send them back to this contract
        for (uint i = 0; i < tokenIds.length; i++) tokens[tokenIds[i]].staked = false;

        accounts[msg.sender].metAllowance +=  vaultDoor.earningInfo(tokenIds).earned; // set metAllowance of unstaked blocks


        // Loop into all tokens to gather their $MET earnings by owner and set their allowance. 
        // TO DO : Perform a gas cost test by setting the metAllowance by tokenIds and not storing in memory the total array (accounts[tokens[tokenIds[i]].owner].metAllowance)
        address currentOwner;
        address previousOwner;
        uint256[] memory currentOwnerIds;
        uint counter = 0;

        for (uint i=0; i< tokenIdsList.length; i++){ // loop through all tokens

            currentOwner = tokens[tokenIds[i]].owner; // store the owner of the current token
            if (currentOwner != previousOwner && i>0){ // if the owner if different from the owner of the previous token
                accounts[tokens[tokenIds[i-1]].owner].metAllowance += vaultDoor.earningInfo(currentOwnerIds).earned; // get the met earnings on all the previous owner tokens and set metAllowance
                delete currentOwnerIds; // reset the array
                counter = 0;
            }
            currentOwnerIds[counter] = tokenIdsList[i]; // add the current token to the current owner array
            counter++; 
            previousOwner = currentOwner;
        
        }

        vaultDoor.unstake(tokenIds, tokenIdsList); // unstake the selected blocks and claim for ALL tokens (otherwise the boost is lost)
    }

    function receiveBatch (address owner, uint256[] calldata tokenIds) internal { // Internal function used to deposit 1 or more Blocks
        accounts[owner].balance += uint24(tokenIds.length);
        for (uint i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            Stake storage s = tokens[tokenId];
            require(s.owner == address(0), "Token is already staked");

            IERC721 nft = IERC721(IMetroNFTLookup(nftLookupAddress).getNFTContractAddress(tokenId));
            
            s.owner = owner;
            s.timestamp = uint40(block.timestamp);
            accounts[owner].AccountTokenIdToIndex[tokenIds[i]] = accounts[owner].tokenIds.length; // store the index of the tokenId in the personal array
            accounts[owner].tokenIds.push(tokenIds[i]); // push the tokenId to the personnal array the the previous index
            tokenIdToIndex[tokenIds[i]] = tokenIdsList.length; // store the index of the tokenId in the global array
            tokenIdsList.push(tokenIds[i]); // push the tokenId in the global array


            emit BlockReceived(owner, tokenId, address(this), uint40(block.timestamp));
            _delegatecall(address(nft),abi.encodeWithSignature("transferFrom(address from, address to, uint256 tokenId)", msg.sender, address(this), tokenId));
        }
    }

    function sendBatch (address owner, address to, uint256[] calldata tokenIds) internal { // Internal function used to withdraw 1 or more Blocks
        accounts[owner].balance -= uint24(tokenIds.length);
        for (uint i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];      
            Stake memory staked = tokens[tokenId];
            require(owner == staked.owner, "Not an owner");

            delete tokens[tokenId];
            remove(owner, tokenIds[i]);
            delete tokenIdToIndex[tokenIds[i]];
            delete accounts[owner].AccountTokenIdToIndex[tokenIds[i]];

            IERC721 nft = IERC721(IMetroNFTLookup(nftLookupAddress).getNFTContractAddress(tokenId));
            emit BlockSent(staked.owner, tokenId, block.timestamp);
            _delegatecall(address(nft),abi.encodeWithSignature("transferFrom(address from, address to, uint256 tokenId)", address(this), to, tokenId));
        } 
    }

    function _delegatecall(address target, bytes memory data) internal returns (bytes memory) { // performs a delegatecall and allow to revert on the called function error
        (bool success, bytes memory returndata) = target.delegatecall(data);
        if (!success) {
            if (returndata.length == 0) revert();
            assembly {
                revert(add(32, returndata), mload(returndata))
            }
        }
        return returndata;
    }
    modifier onlyBlockOwner (uint256[] calldata tokenIds) {
        for (uint i = 0; i < tokenIds.length; i++) {
            require (tokens[tokenIds[i]].owner == msg.sender, "Not an owner");
        }
        _;
    }
}
interface IVaultDoor { // Interface for MetroVaultDoor.sol
    struct EarningInfo {
        uint256 earned;
        uint256 earnRatePerSecond;
    }
    function stake(uint256[] calldata tokenIds) external;
    function unstake(uint256[] calldata tokenIds, uint256[] calldata claimTokenIds) external;
    function claim(uint256[] calldata tokenIds) external;
    function earningInfo(uint256[] calldata tokenIds) external view returns (EarningInfo memory);
}

interface IMetroNFTLookup { // Interface for MetroNFTLookup.sol
    function getNFTContractAddress(uint256 tokenId) external view returns (address);
}

interface IMetroVaultStorage { // Interface for MetroVaultStorage.sol
    struct Stake {
        address owner;
        uint40 timestamp;
        uint16 cityId;
        uint40 extra;
    }

    struct Account {
        uint24 balance;
        uint232 extra;
    }
    function getStake(uint256 tokenId) external returns (Stake memory);
    function getAccount(address owner) external returns (Account memory);

    function setStake(uint256 tokenId, Stake calldata newStake) external;
    function setStakeTimestamp(uint256[] calldata tokenIds, uint40 timestamp) external;
    function setStakeCity(uint256[] calldata tokenIds, uint16 cityId, bool resetTimestamp) external;
    function setStakeExtra(uint256[] calldata tokenIds, uint40 extra, bool resetTimestamp) external;
    function setStakeOwner(uint256[] calldata tokenIds, address owner, bool resetTimestamp) external;
    function changeStakeOwner(uint256 tokenId, address newOwner, bool resetTimestamp) external;

    function setAccountsExtra(address[] calldata owners, uint232[] calldata extras) external;
    function setAccountExtra(address owner, uint232 extra) external;

    function deleteStake(uint256[] calldata tokenIds) external;
    
    function stakeBlocks(address owner, uint256[] calldata tokenIds, uint16 cityId, uint40 extra) external;
    function stakeFromMint(address owner, uint256[] calldata tokenIds, uint16 cityId, uint40 extra) external;
    function unstakeBlocks(address owner, uint256[] calldata tokenIds) external;
    function unstakeBlocksTo(address owner, address to, uint256[] calldata tokenIds) external;
    
    function tokensOfOwner(address account, uint256 start, uint256 stop) external view returns (uint256[] memory);

    function stakeBlocks(
      address owner,
      uint256[] calldata tokenIds,
      uint16[] calldata cityIds,
      uint40[] calldata extras,
      uint40[] calldata timestamps
    ) external;
}

interface IMetroBlockInfo { // Interface for MetroBlockInfo.sol
    function getBlockScore(uint256 tokenId) external view returns (uint256 score);
    function getBlockInfo(uint256 tokenId) external view returns (uint256 info);
    function getHoodBoost(uint256[] calldata tokenIds) external view returns (uint256 score);
}
