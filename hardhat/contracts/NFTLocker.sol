// SPDX-License-Identifier: GNU-GPL v3.0 or later

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IOutputReceiver.sol";
import "./interfaces/ITokenVault.sol";
import "./interfaces/IRevest.sol";
import "./interfaces/IFNFTHandler.sol";
import "./interfaces/ILockManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title
 * @dev
 */

contract NFTLocker is IOutputReceiver, Ownable, ERC165, ERC721Holder {
    using SafeERC20 for IERC20;

    address public addressRegistry;
    string public  metadata;
    uint public constant PRECISION = 10**27;

    struct ERC721Data {
        uint[] tokenIds;
        uint supply;
        uint index;
        address erc721;
    }

    struct Balance {
        uint curMul;
        uint lastMul;
    }

    event AirdropEvent(address indexed token, address indexed erc721, uint indexed update_index, uint amount);
    event LockedNFTEvent(address indexed erc721, uint indexed tokenId, uint indexed fnftId, uint update_index);

    uint public updateIndex = 1;

    // Map fnftId to ERC721Data object for that token
    mapping (uint => ERC721Data) public nfts;

    // Map ERC20 token address to latest update index for that token
    mapping (address => bytes32) public globalBalances;

    // Map ERC20 token updates from updateIndex to balances
    mapping(bytes32 => Balance) public updateEvents;

    // Map fnftId to mapping of ERC20 tokens to multipliers
    mapping (uint => mapping (address => uint)) localMuls;

    constructor(address _provider, string memory _meta) {
        addressRegistry = _provider;
        metadata = _meta;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IOutputReceiver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// Allows for a user to deposit ERC721s
    /// @param endTime UTC for when the enclosing FNFT will unlock
    /// @param tokenIds a list of ERC721 Ids to lock
    /// @param recipients who will receive the resulting FNFTs
    /// @param erc721 the address of the ERC721 contract
    /// @param quantities how many FNFTs to give per recipient, if fractionalization is desired
    /// @param hardLock whether to allow transfer of the enclosing ERC1155 FNFT 
    /// @dev you should not stake and fractionalize at the same time, as this results in a race condition
    function mintTimeLock(
        uint endTime,
        uint[] memory tokenIds,
        address[] memory recipients,
        address erc721,
        uint[] memory quantities,
        bool hardLock
    ) external payable returns (uint fnftId) {
        (uint supply, IRevest.FNFTConfig memory fnftConfig) = preMint(tokenIds, quantities, erc721, hardLock);

        // Mint FNFT
        fnftId = getRevest().mintTimeLock(endTime, recipients, quantities, fnftConfig);


        // Store data
        nfts[fnftId] = ERC721Data(tokenIds, supply, updateIndex, erc721);
    }

    /// Allows for a user to deposit ERC721s into a value-locked FNFT
    /// @param primaryAsset the asset to compare the price of
    /// @param compareTo the asset to measure price in
    /// @param unlockValue the price value to unlock at
    /// @param unlockRisingEdge whether to unlock when price goes high or low
    /// @param oracleDispatch which modular oracle manager to use
    /// @param tokenIds a list of ERC721 Ids to lock
    /// @param recipients who will receive the resulting FNFTs
    /// @param erc721 the address of the ERC721 contract
    /// @param quantities how many FNFTs to give per recipient, if fractionalization is desired
    /// @param hardLock whether to allow transfer of the enclosing ERC1155 FNFT 
    /// @dev you should not stake and fractionalize at the same time, as this results in a race condition
    function mintValueLock(
        address primaryAsset,
        address compareTo,
        uint unlockValue,
        bool unlockRisingEdge,
        address oracleDispatch,
        uint[] memory tokenIds,
        address[] memory recipients,
        address erc721,
        uint[] memory quantities,
        bool hardLock
    ) external payable returns (uint fnftId) {
        (uint supply, IRevest.FNFTConfig memory fnftConfig) = preMint(tokenIds, quantities, erc721, hardLock);

        // Mint FNFT
        fnftId = getRevest().mintValueLock(primaryAsset, compareTo, unlockValue, unlockRisingEdge, oracleDispatch, recipients, quantities, fnftConfig);

        // Store data
        nfts[fnftId] = ERC721Data(tokenIds, supply, updateIndex, erc721);
    }

    /// Allows for a user to deposit ERC721s into a custom-locked FNFT
    /// @param trigger the address where the address lock contract is located
    /// @param arguments a bytes array that represents ABI packed arguments for pass-through
    /// @param tokenIds a list of ERC721 Ids to lock
    /// @param recipients who will receive the resulting FNFTs
    /// @param erc721 the address of the ERC721 contract
    /// @param quantities how many FNFTs to give per recipient, if fractionalization is desired
    /// @param hardLock whether to allow transfer of the enclosing ERC1155 FNFT 
    /// @dev you should not stake and fractionalize at the same time, as this results in a race condition
    function mintAddressLock(
        address trigger,
        bytes memory arguments,
        uint[] memory tokenIds,
        address[] memory recipients,
        address erc721,
        uint[] memory quantities,
        bool hardLock
    ) external payable returns (uint fnftId) {
        (uint supply, IRevest.FNFTConfig memory fnftConfig) = preMint(tokenIds, quantities, erc721, hardLock);

        // Mint FNFT
        fnftId = getRevest().mintAddressLock(trigger, arguments, recipients, quantities, fnftConfig);

        // Store data
        nfts[fnftId] = ERC721Data(tokenIds, supply, updateIndex, erc721);
    }

    function preMint(uint[] memory tokenIds, uint[] memory quantities, address erc721, bool hardLock) internal returns (uint supply, IRevest.FNFTConfig memory fnftConfig) {
        supply = quantities[0];
        if(quantities.length > 1) {
            // We are definitely fractionalizing an ERC721
            for(uint i = 1; i < quantities.length; i++) {
                supply += quantities[i];
            }
        }

        // Config FNFT
        fnftConfig.pipeToContract = address(this);
        fnftConfig.nontransferrable = hardLock;

        uint fnftId = IFNFTHandler(IAddressRegistry(addressRegistry).getRevestFNFT()).getNextId();
        // Transfer NFT to this contract
        // Implicitly checks if holder owns NFT
        for(uint i = 0; i < tokenIds.length; i++) {
            IERC721(erc721).safeTransferFrom(_msgSender(), address(this), tokenIds[i]);
            emit LockedNFTEvent(erc721, tokenIds[i], fnftId, updateIndex);
        }
    }

    /// Function to allow for the withdrawal of the underlying NFT
    function receiveRevestOutput(
        uint fnftId,
        address,
        address payable owner,
        uint quantity
    ) external override  {
        require(_msgSender() == IAddressRegistry(addressRegistry).getTokenVault(), 'E016');
        ERC721Data memory nft = nfts[fnftId];
        require(quantity == nft.supply, 'E073');

        // Transfer ownership of the underlying NFT to the caller
        for(uint i = 0; i < nft.tokenIds.length; i++) {
            IERC721(nft.erc721).safeTransferFrom(address(this), owner, nft.tokenIds[i]);
        }
        // Unfortunately, we do not have a way to detect what tokens need to be auto withdrawn from
        // So you will need to claim all rewards from your NFT prior to withdrawing it
    }

    function airdropTokens(uint amount, address token, address erc721) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint totalAllocPoints = IERC721(erc721).balanceOf(address(this));
        require(totalAllocPoints > 0, 'E076');
        uint newMulComponent = amount * PRECISION / totalAllocPoints;
        uint current = updateEvents[globalBalances[token]].curMul;
        if(current == 0) {
            // New token, need to initialize to precision
            current = PRECISION;
        }
        Balance memory bal = Balance(current + newMulComponent, current);
        bytes32 key = getBalanceKey(updateIndex, token);
        updateEvents[key] = bal;
        globalBalances[token] = key;
        emit AirdropEvent(token, erc721, updateIndex, amount);
        updateIndex++;
    }

    /// Allows a user to claim their rewards
    /// @param fnftId the FNFT ID to claim the rewards for
    /// @param timeIndex the time index to look at. Must be discovered off-chain as closest to staking event
    function claimRewards(
        uint fnftId,
        uint timeIndex,
        address token
    ) external {
        IAddressRegistry reg = IAddressRegistry(addressRegistry);
        require(IFNFTHandler(reg.getRevestFNFT()).getBalance(_msgSender(), fnftId) > 0, 'E064');
        _claimRewards(fnftId, timeIndex, token);
    }

    function claimRewardsBatch(
        uint fnftId,
        uint[] memory timeIndices,
        address[] memory tokens
    ) external {
        require(timeIndices.length == tokens.length, 'E067');
        IAddressRegistry reg = IAddressRegistry(addressRegistry);
        require(IFNFTHandler(reg.getRevestFNFT()).getBalance(_msgSender(), fnftId) > 0, 'E064');
        for(uint i = 0; i < timeIndices.length; i++) {
            _claimRewards(fnftId, timeIndices[i], tokens[i]);
        }
    }

    // Time index will correspond to a DepositEvent created after the NFT was staked
    function _claimRewards(
        uint fnftId,
        uint timeIndex,
        address token
    ) internal {
        uint localMul = localMuls[fnftId][token];
        require(nfts[fnftId].index <= timeIndex || localMul > 0, 'E075');
        Balance memory bal =updateEvents[globalBalances[token]];

        if(localMul == 0) {
            // Need to derive mul for token when NFT staked - use timeIndex
            localMul = updateEvents[getBalanceKey(timeIndex, token)].lastMul;
        }
        uint rewards = (bal.curMul - localMul) * nfts[fnftId].tokenIds.length / PRECISION;
        localMuls[fnftId][token] = bal.curMul;
        IERC20(token).safeTransfer(_msgSender(), rewards);
    }

    function getCustomMetadata(uint) external view override returns (string memory) {
        return metadata;
    }

    function getValue(uint fnftId) external view override returns (uint) {
        return nfts[fnftId].tokenIds.length;
    }

    function getAsset(uint fnftId) external view override returns (address) {
        return nfts[fnftId].erc721;
    }

    function getOutputDisplayValues(uint fnftId) external view override returns (bytes memory) {
        ERC721Data memory nft = nfts[fnftId];
        return abi.encode(nft.tokenIds, nft.supply, nft.erc721);
    }

    function setAddressRegistry(address addressRegistry_) external override onlyOwner {
        addressRegistry = addressRegistry_;
    }

    function getAddressRegistry() external view override returns (address) {
        return addressRegistry;
    }

    function getRevest() internal view returns (IRevest) {
        return IRevest(IAddressRegistry(addressRegistry).getRevest());
    }

    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     *
     * Always returns `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function getBalanceKey(uint num, address add) internal pure returns (bytes32 hash_) {
        hash_ = keccak256(abi.encode(num, add));
    }
}
