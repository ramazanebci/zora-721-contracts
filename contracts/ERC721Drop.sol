// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {ERC721AUpgradeable} from "erc721a-upgradeable/ERC721AUpgradeable.sol";
import {IERC2981Upgradeable, IERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {MerkleProofUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";

import {IZoraFeeManager} from "./interfaces/IZoraFeeManager.sol";
import {IMetadataRenderer} from "./interfaces/IMetadataRenderer.sol";
import {IZoraDrop} from "./interfaces/IZoraDrop.sol";
import {IOwnable} from "./interfaces/IOwnable.sol";
import {OwnableSkeleton} from "./utils/OwnableSkeleton.sol";

/**
 * @notice ZORA NFT Base contract for Drops and Editions
 *
 * @dev For drops: assumes 1. linear mint order, 2. max number of mints needs to be less than max_uint64
 *       (if you have more than 18 quintillion linear mints you should probably not be using this contract)
 * @author iain@zora.co
 *
 */
contract ERC721Drop is
    ERC721AUpgradeable,
    IERC2981Upgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    IZoraDrop,
    OwnableSkeleton
{
    using AddressUpgradeable for address payable;

    event SalesConfigChanged(address indexed changedBy);
    event FundsRecipientChanged(address indexed newAddress);

    /// @notice Error string constants
    string private constant SOLD_OUT = "Sold out";
    string private constant TOO_MANY = "Too many";

    /// @notice Access control roles
    bytes32 public immutable MINTER_ROLE = keccak256("MINTER");
    bytes32 public immutable SALES_MANAGER_ROLE = keccak256("SALES_MANAGER");

    /// @notice General configuration for NFT Minting and bookkeeping
    struct Configuration {
        /// @dev Metadata renderer
        IMetadataRenderer metadataRenderer;
        /// @dev Total size of edition that can be minted
        uint64 editionSize;
        /// @dev Royalty amount in bps
        uint16 royaltyBPS;
        /// @dev Funds recipient for sale
        address payable fundsRecipient;
    }

    /// @notice Sales states and configuration
    struct SalesConfiguration {
        /// @dev Is the public sale active
        bool publicSaleActive;
        /// @dev Is the presale active
        bool presaleActive;
        /// @dev Is the public sale active
        uint64 publicSalePrice;
        /// @dev Max purchase number per txn
        uint32 maxSalePurchasePerAddress;
        /// @dev Presale merkle root
        bytes32 presaleMerkleRoot;
    }

    /// @notice Configuration for NFT minting contract storage
    Configuration public config;

    /// @notice Sales configuration
    SalesConfiguration public salesConfig;

    /// @dev ZORA V3 transfer helper address for auto-approval
    address private immutable zoraERC721TransferHelper;

    /// @dev Mapping for contract mint protection
    mapping(address => uint256) private mintedByContract;

    /// @dev Zora Fee Manager Address
    IZoraFeeManager public immutable zoraFeeManager;

    /// @notice Only allow for users with admin access
    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Only admin allowed");

        _;
    }

    modifier canMintTokens(uint256 quantity) {
        require(quantity + _totalMinted() <= config.editionSize, TOO_MANY);

        _;
    }

    modifier onlyPresaleActive() {
        require(salesConfig.presaleActive, "Presale inactive");

        _;
    }

    modifier onlyPublicSaleActive() {
        require(salesConfig.publicSaleActive, "Sale inactive");

        _;
    }

    function _lastMintedTokenId() internal view returns (uint256) {
        return _currentIndex - 1;
    }

    /**
     * To change the starting tokenId, please override this function.
     */
    function _startTokenId() internal pure override returns (uint256) {
        return 1;
    }

    /// @notice Only a given role has access or admin
    /// @param role role to check for alongside the admin role
    modifier onlyRoleOrAdmin(bytes32 role) {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(role, msg.sender),
            "Does not have proper role or admin"
        );

        _;
    }

    /// @notice Global constructor – these variables will not change with further proxy deploys
    /// @param _zoraFeeManager Zora Fee Manager
    /// @param _zoraERC721TransferHelper Transfer helper
    constructor(
        IZoraFeeManager _zoraFeeManager,
        address _zoraERC721TransferHelper
    ) {
        zoraFeeManager = _zoraFeeManager;
        zoraERC721TransferHelper = _zoraERC721TransferHelper;
    }

    ///  @param _owner User that owns and can mint the edition, gets royalty and sales payouts and can update the base url if needed.
    ///  @param _fundsRecipient Wallet/user that receives funds from sale
    ///  @param _editionSize Number of editions that can be minted in total. If 0, unlimited editions can be minted.
    ///  @param _royaltyBPS BPS of the royalty set on the contract. Can be 0 for no royalty.
    ///  @dev Function to create a new edition. Can only be called by the allowed creator
    ///       Sets the only allowed minter to the address that creates/owns the edition.
    ///       This can be re-assigned or updated later
    function initialize(
        string memory _name,
        string memory _symbol,
        address _owner,
        address payable _fundsRecipient,
        uint64 _editionSize,
        uint16 _royaltyBPS,
        IMetadataRenderer _metadataRenderer,
        bytes memory _metadataRendererInit
    ) public initializer {
        __ERC721A_init(_name, _symbol);
        __AccessControl_init();
        // Setup the owner role
        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        // Set ownership to original sender of contract call
        _setOwner(_owner);

        require(
            config.royaltyBPS < 50_01,
            "Royalty BPS cannot be greater than 50%"
        );

        config.editionSize = _editionSize;
        config.metadataRenderer = _metadataRenderer;
        config.royaltyBPS = _royaltyBPS;
        config.fundsRecipient = _fundsRecipient;
        _metadataRenderer.initializeWithData(_metadataRendererInit);
    }

    /// @dev Getter for admin role associated with the contract to handle metadata
    /// @return boolean if address is admin
    function isAdmin(address user) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, user);
    }

    /// @param tokenId Token ID to burn
    /// @notice User burn function for token id
    function burn(uint256 tokenId) public {
        _burn(tokenId, true);
    }

    /// @dev Get royalty information for token
    /// @param _salePrice Sale price for the token
    function royaltyInfo(uint256, uint256 _salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        if (config.fundsRecipient == address(0x0)) {
            return (config.fundsRecipient, 0);
        }
        return (
            config.fundsRecipient,
            (_salePrice * config.royaltyBPS) / 10_000
        );
    }

    function saleDetails()
        external
        view
        returns (IZoraDrop.SaleDetails memory)
    {
        return
            IZoraDrop.SaleDetails({
                publicSaleActive: salesConfig.publicSaleActive,
                publicSalePrice: salesConfig.publicSalePrice,
                presaleActive: salesConfig.presaleActive,
                totalMinted: _totalMinted(),
                maxSupply: config.editionSize,
                maxSalePurchasePerAddress: salesConfig.maxSalePurchasePerAddress
            });
    }

    /// @dev Number of NFTs the user has minted per address
    /// @param minter to get count for
    function mintedPerAddress(address minter) external view returns (uint256) {
        return _numberMinted(minter);
    }

    /// @dev Setup auto-approval for Zora v3 access to sell NFT
    ///      Still requires approval for module
    /// @param nftOwner owner of the nft
    /// @param operator operator wishing to transfer/burn/etc the NFTs
    function isApprovedForAll(address nftOwner, address operator)
        public
        view
        override(ERC721AUpgradeable)
        returns (bool)
    {
        if (operator == zoraERC721TransferHelper) {
            return true;
        }
        return super.isApprovedForAll(nftOwner, operator);
    }

    /** PUBLIC MINTING FUNCTIONS */

    /**
      @dev This allows the user to purchase a edition edition
           at the given price in the contract.
      @dev no need for re-entrancy guard since no safe_xxx functions are used
     */
    function purchase(uint256 quantity)
        external
        payable
        canMintTokens(quantity)
        onlyPublicSaleActive
        returns (uint256)
    {
        uint256 salePrice = salesConfig.publicSalePrice;
        require(salePrice > 0, "Not for sale");
        // TODO(iain): Should Use tx.origin here to allow for minting from proxy contracts to not break limit and require unique accounts
        require(msg.value == salePrice * quantity, "Wrong price");
        require(
            _numberMinted(_msgSender()) <=
                salesConfig.maxSalePurchasePerAddress,
            TOO_MANY
        );

        _mintNFTs(_msgSender(), quantity);
        uint256 firstMintedTokenId = _lastMintedTokenId() - quantity;

        emit IZoraDrop.Sale({
            to: _msgSender(),
            quantity: quantity,
            pricePerToken: salePrice,
            firstPurchasedTokenId: firstMintedTokenId
        });
        return firstMintedTokenId;
    }

    function _mintNFTs(address to, uint256 quantity) internal {
        _mint({to: to, quantity: quantity, _data: "", safe: false});
    }

    /**
        @notice Merkle-tree based presale purchase function
     */
    function purchasePresale(
        uint256 quantity,
        uint256 maxQuantity,
        uint256 pricePerToken,
        bytes32[] memory merkleProof
    )
        external
        payable
        canMintTokens(quantity)
        onlyPresaleActive
        returns (uint256)
    {
        require(
            MerkleProofUpgradeable.verify(
                merkleProof,
                salesConfig.presaleMerkleRoot,
                keccak256(
                    abi.encodePacked(msg.sender, maxQuantity, pricePerToken)
                )
            ),
            "Needs to be approved"
        );
        require(msg.value == pricePerToken * quantity, "Wrong price");
        require(_numberMinted(_msgSender()) <= maxQuantity, TOO_MANY);

        _mintNFTs(_msgSender(), quantity);
        uint256 firstMintedTokenId = _lastMintedTokenId() - quantity;

        emit IZoraDrop.Sale({
            to: _msgSender(),
            quantity: quantity,
            pricePerToken: pricePerToken,
            firstPurchasedTokenId: firstMintedTokenId
        });

        return firstMintedTokenId;
    }

    // TODO(iain): Add signature based mint function

    /** ADMIN MINTING FUNCTIONS */

    /// @notice Mint admin
    /// @param recipient recipient to mint to
    /// @param quantity quantity to mint
    function adminMint(address recipient, uint256 quantity)
        external
        onlyRoleOrAdmin(MINTER_ROLE)
        canMintTokens(quantity)
        returns (uint256)
    {
        _mintNFTs(recipient, quantity);

        return _lastMintedTokenId();
    }

    /// @dev This mints multiple editions to the given list of addresses.
    /// @param recipients list of addresses to send the newly minted editions to
    function adminMintAirdrop(address[] calldata recipients)
        external
        override
        onlyRoleOrAdmin(MINTER_ROLE)
        canMintTokens(recipients.length)
        returns (uint256)
    {
        uint256 atId = _currentIndex;
        uint256 startAt = atId;

        unchecked {
            for (
                uint256 endAt = atId + recipients.length;
                atId < endAt;
                atId++
            ) {
                _mintNFTs(recipients[atId - startAt], 1);
            }
        }
        return _lastMintedTokenId();
    }

    /// @dev Set new owner for royalties / opensea
    /// @param newOwner new owner to set
    function setOwner(address newOwner) public onlyAdmin {
        _setOwner(newOwner);
    }

    ///  @dev This sets the sales configuration
    function setSaleConfiguration(SalesConfiguration memory newConfig)
        external
        onlyAdmin
    {
        salesConfig = newConfig;
        emit SalesConfigChanged(_msgSender());
    }

    /// @dev Set a different funds recipient
    function setFundsRecipient(address payable newRecipientAddress)
        external
        onlyRoleOrAdmin(SALES_MANAGER_ROLE)
    {
        config.fundsRecipient = newRecipientAddress;
        emit FundsRecipientChanged(newRecipientAddress);
    }

    /// @dev Gets the zora fee for amount of withdraw
    /// @param amount amount of funds to get fee for
    function zoraFeeForAmount(uint256 amount)
        public
        returns (address payable, uint256)
    {
        (address payable recipient, uint256 bps) = zoraFeeManager
            .getZORAWithdrawFeesBPS(address(this));
        return (recipient, (amount * bps) / 10_000);
    }

    /// @dev This withdraws ETH from the contract to the contract owner.
    function withdraw()
        external
        onlyRoleOrAdmin(SALES_MANAGER_ROLE)
        nonReentrant
    {
        uint256 funds = address(this).balance;
        (address payable feeRecipient, uint256 zoraFee) = zoraFeeForAmount(
            funds
        );

        // No need for gas limit to trusted address.
        feeRecipient.sendValue(zoraFee);
        funds -= zoraFee;
        // No need for gas limit to trusted address.
        config.fundsRecipient.sendValue(funds);
    }

    /// Simple override for owner interface.
    /// @return user owner address
    function owner()
        public
        view
        override(OwnableSkeleton, IZoraDrop)
        returns (address)
    {
        return super.owner();
    }

    /// @notice Contract URI Getter, proxies to metadataRenderer
    /// @return Contract URI
    function contractURI() external view returns (string memory) {
        return config.metadataRenderer.contractURI();
    }

    /// @notice Token URI Getter, proxies to metadataRenderer
    /// @param tokenId id of token to get URI for
    /// @return Token URI
    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        return config.metadataRenderer.tokenURI(tokenId);
    }

    /// @notice ERC165 supports interface
    /// @param interfaceId interface id to check if supported
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(
            IERC165Upgradeable,
            ERC721AUpgradeable,
            AccessControlUpgradeable
        )
        returns (bool)
    {
        return
            super.supportsInterface(interfaceId) ||
            type(IOwnable).interfaceId == interfaceId ||
            type(IERC2981Upgradeable).interfaceId == interfaceId;
    }
}
