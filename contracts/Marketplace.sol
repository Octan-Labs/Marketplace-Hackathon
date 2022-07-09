// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IManagement.sol";
import "./interfaces/IArchive.sol";

contract Marketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct SaleInfo {
        uint256 saleID;
        address seller;
        address nftToken;
        address paymentToken;
        uint256 nftType;
        uint256 tokenID;
        uint256 onSaleAmt;
        uint256 unitPrice;
        bytes sSignature;               //  Signature generated by Seller
    }

    struct RoyaltyInfo {
        uint256 royalty;
        address receiver;
    }

    bytes32 private constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 private constant AUTHORIZER_ROLE = keccak256("AUTHORIZER_ROLE");
    uint256 private constant NFT721 = 721;
    uint256 private constant NFT1155 = 1155;
    uint256 public constant FEE_DENOMINATOR = 10**4;

    IManagement public management;
    IArchive public archive;

    mapping(address => RoyaltyInfo) public royalties;

    event Purchased(
        uint256 indexed saleId,
        address indexed buyer,
        address indexed seller,
        uint256 purchasedAmt,
        uint256 commissionFee,
        uint256 royaltyFee,
        uint256 payToSeller
    );

    event Canceled(address indexed _seller, uint256 _saleId);

    modifier onlyManager() {
        require(
            management.hasRole(MANAGER_ROLE, msg.sender), "Only Manager"
        );
        _;
    }

    constructor(IManagement _management, IArchive _archive) {
        management = _management;
        archive = _archive;
    }

    /**
        @notice Change a new Management contract
        @dev Caller must have MANAGER_ROLE
        @param _newManagement       Address of new Management contract
    */
    function updateManagement(address _newManagement) external onlyManager {
        require(_newManagement != address(0), "Set zero address");

        management = IManagement(_newManagement);
    }

    /**
        @notice Set Royalty Fee of one Collection
        @dev    Caller must have MANAGER_ROLE

        @param _collection       Address of new NFT Token (ERC721/ERC1155/Collection) contract
        @param _receiver         Address of Receiver to transfer royalty fee
        @param _royalty          Royalty fee (i.e. royalty_fee = 5% => _royalty = 500 = 500 / 10,000 = 5 / 100)
    */
    function setRoyalty(address _collection, address _receiver, uint256 _royalty) external onlyManager {
        require(management.collections(_collection), "Collection not supported");
        require(_royalty != 0, "Invalid setting");

        royalties[_collection].royalty = _royalty;
        royalties[_collection].receiver = _receiver;
    }

    /**
        @notice Save `_saleId` when Seller cancels 'On Sale' items
        @dev    Caller can be ANY

        @param _saleId          An unique identification number of Sale Info
        @param _signature       A signature generated by AUTHORIZER_ROLE
    */
    function cancelOnSale(uint256 _saleId, bytes calldata _signature) external {
        require(!archive.prevSaleIds(_saleId), "SaleId already recorded");

        address _seller = msg.sender;
        _checkCancelSignature(_saleId, _seller, _signature);
        
        archive.cancel(_saleId);

        emit Canceled(_seller, _saleId);
    }

    /**
        @notice Purchase item
        @dev    Caller can be ANY

        @param _expiry              Expire blocknumber of authorized signature
        @param _purchaseAmt         A purchasing amount
        @param _saleInfo            A struct of sale information
        @param _aSignature          A signature generated by AUTHORIZER_ROLE
    */
    function purchase(
        uint256 _expiry,
        uint256 _purchaseAmt,
        SaleInfo calldata _saleInfo,
        bytes calldata _aSignature
    ) external payable nonReentrant {
        require(block.number <= _expiry, "Authorized Signature expired");
        require(_saleInfo.nftType == NFT721 || _saleInfo.nftType == NFT1155, "Invalid type");

        //  Checking purchase and payment info
        //      + validate purchasing amount
        //      + validate payment token
        //      + If payment token is native coin, checking msg.value
        _checkPurchase(
            _saleInfo.saleID, _saleInfo.nftType, _saleInfo.onSaleAmt, 
            _saleInfo.unitPrice, _purchaseAmt, _saleInfo.paymentToken
        );

        //  Validate two signatures
        //  - `sSignatrue` is generated by Seller
        //  - `aSignature` is generated by Authorizer
        address _buyer = msg.sender;
        _checkSignatures(_buyer, _expiry, _purchaseAmt, _saleInfo, _aSignature);

        (uint256 _commissionFee, uint256 _royaltyFee, uint256 _payToSeller) = _calcPayment(
            _saleInfo.unitPrice, _purchaseAmt, management.commissionFee(), royalties[_saleInfo.nftToken].royalty
        );

        if (_commissionFee != 0)
            _makePayment(
                _saleInfo.paymentToken, _buyer, management.treasury(), _commissionFee
            );

        if (_royaltyFee != 0)
            _makePayment(
                _saleInfo.paymentToken, _buyer, royalties[_saleInfo.nftToken].receiver, _royaltyFee
            );

        _makePayment(_saleInfo.paymentToken, _buyer, _saleInfo.seller, _payToSeller);

        //  transfer NFT item to Buyer
        //  - If Seller has not yet setApproveForAll, this transaction is likely reverted
        //  - If Seller is not the owner of `tokenId` nor owning insufficient amount of items, this transaction is likely reverted
        _transferItem(
            _saleInfo.nftToken, _saleInfo.nftType, _saleInfo.seller, _buyer, _saleInfo.tokenID, _purchaseAmt
        );

        emit Purchased(
            _saleInfo.saleID, _buyer, _saleInfo.seller, _purchaseAmt,
            _commissionFee, _royaltyFee, _payToSeller
        );
    }

    function _checkCancelSignature(uint256 _saleId, address _seller, bytes calldata _signature) private view {
        bytes32 _data = ECDSA.toEthSignedMessageHash(
            keccak256(abi.encodePacked(_saleId, _seller))
        );
        require(
            management.hasRole(AUTHORIZER_ROLE, ECDSA.recover(_data, _signature)), "Invalid signature"
        );
    }

    function _checkSignatures(
        address _buyer,
        uint256 _expiry,
        uint256 _purchaseAmt,
        SaleInfo calldata _saleInfo,
        bytes calldata _aSignature
    ) private view {
        bytes32 _txHash = ECDSA.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    _saleInfo.saleID, _saleInfo.seller, _saleInfo.nftToken, _saleInfo.paymentToken,
                    _saleInfo.nftType, _saleInfo.tokenID, _saleInfo.onSaleAmt, _saleInfo.unitPrice
                )
            )
        );
        require(
            ECDSA.recover(_txHash, _saleInfo.sSignature) == _saleInfo.seller, "Invalid seller signature"
        );

        _txHash = ECDSA.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(_saleInfo.sSignature, _buyer, _purchaseAmt, _expiry)
            )
        );
        require(
            management.hasRole(AUTHORIZER_ROLE, ECDSA.recover(_txHash, _aSignature)), "Invalid authorized signature"
        );
    }

    function _checkPurchase(uint256 _saleId, uint256 _nftType, uint256 _onSaleAmt, uint256 _price, uint256 _amount, address _token) private {
        require(!archive.prevSaleIds(_saleId), "Sale canceled");
        
        //  Then, checking purchasing amount
        //  If '_amount' is greater than 'currentOnSale' -> revert
        //  In success, update 'currentOnSale'
        require(
            _nftType == NFT721 && _onSaleAmt == 1 ||
            _nftType == NFT1155 && _onSaleAmt != 0,
            "Invalid OnSaleAmt"
        );

        //  For first purchase, the 'currentOnSale' is updated for the `saleId`. Then, locl `OnSale` state
        //  For next purchases, 'currentOnSale' will be deducted until reaching zero
        //  The 'OnSale' state will bind to the 'saleId' and won't be reset
        if ( archive.getLocked(_saleId) ) {
            //  if `currentOnSale` < `_amount` -> underflow -> revert
            archive.setCurrentOnSale(
                _saleId, archive.getCurrentOnSale(_saleId) - _amount
            );
        }
        else {
            archive.setLocked(_saleId);
            archive.setCurrentOnSale(_saleId, _onSaleAmt - _amount);
        }

        if (_token == address(0)) 
            require(_price * _amount == msg.value, "Insufficient payment");
        else 
            require(management.paymentTokens(_token), "Invalid payment token");
    }

    function _makePayment(address _token, address _from, address _to, uint256 _amount) private {
        if (_token == address(0))
            Address.sendValue(payable(_to), _amount);
        else
            IERC20(_token).safeTransferFrom(_from, _to, _amount);
    }

    function _transferItem(
        address _nftToken,
        uint256 _nftType,
        address _from,
        address _to,
        uint256 _id,
        uint256 _amount
    ) private {
        if (_nftType == NFT721)
            IERC721(_nftToken).safeTransferFrom(_from, _to, _id);
        else 
            IERC1155(_nftToken).safeTransferFrom(_from, _to, _id, _amount, "");
    }

    function _calcPayment(
        uint256 _unitPrice,
        uint256 _purchaseAmt,
        uint256 _commissionFeeRate,
        uint256 _royaltyFeeRate
    ) private pure returns (uint256 _fee, uint256 _royalty, uint256 _payToSeller) {
        uint256 _totalPrice = _unitPrice * _purchaseAmt;

        _fee = (_totalPrice * _commissionFeeRate) / FEE_DENOMINATOR;
        _royalty = (_totalPrice * _royaltyFeeRate) / FEE_DENOMINATOR;
        _payToSeller = _totalPrice - _fee - _royalty;
    }
}
