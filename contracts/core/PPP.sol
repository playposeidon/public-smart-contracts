// SPDX-License-Identifier: UNLICENSED
// PLay Poseidon GameCoin Contracts v1.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

interface IERC20Deflationary is IERC20 {

    /**
     * @dev return how many percent of transaction amount is going to be taxed when token holder
      is executing a transfer. Address that in the whitelist is excluded from this fee
     */
    function transferFeePercent() external view returns (uint256);

    /**
     * @dev add an address to tax whitelist
     */
    function addAddressToWhitelist(address whitelistAddress) external;

    /**
     * @dev remove an address from tax whitelist
     */
    function removeAddressFromWhitelist(address whitelistAddress) external;

}

abstract contract BotPrevent {

    function protect(address sender, address receiver, uint256 amount) external virtual;

}

contract GameCoin is AccessControlEnumerable, ERC20Burnable, ERC20Pausable {
    bytes32 public constant WHITELISTER_ROLE = keccak256("WHITELISTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    event EventWhiteList(address indexed target, bool state);

    constructor(string memory name,
        string memory symbol,
        uint256 initialSupply,
        address owner,
        address treasury,
        uint256 treasuryPercent,
        uint256 burnPercent,
        uint256 stopBurnSupply) ERC20(name, symbol){
        _mint(owner, initialSupply);
        _treasuryAddress = treasury;
        _transferFeeTreasuryPercent = treasuryPercent;
        _transferFeeBurnPercent = burnPercent;
        _transferStopBurnWhenLowSupply = stopBurnSupply;

        _setupRole(DEFAULT_ADMIN_ROLE, owner);
        _setupRole(WHITELISTER_ROLE, owner);
        _setupRole(PAUSER_ROLE, owner);
    }

    mapping(address => bool) private _senderWhitelist;
    mapping(address => bool) private _recipientWhitelist;
    address private immutable _treasuryAddress;
    uint256 private immutable _transferFeeTreasuryPercent;
    uint256 private immutable _transferFeeBurnPercent;
    uint256 private immutable _transferStopBurnWhenLowSupply;

    BotPrevent public BP;
    bool public bpEnabled = false;
    bool public BPDisabledForever = false;

    function treasuryAddress() external view returns (address){
        return _treasuryAddress;
    }

    function transferFeeTreasuryPercent() external view returns (uint256){
        return _transferFeeTreasuryPercent;
    }

    function transferFeeBurnPercent() external view returns (uint256){
        return _transferFeeBurnPercent;
    }

    function transferStopBurnWhenLowSupply() external view returns (uint256){
        return _transferStopBurnWhenLowSupply;
    }

    function transferFeePercent() external view returns (uint256){
        return _transferFeeTreasuryPercent + _transferFeeBurnPercent;
    }

    function addAddressToWhitelist(address whitelistAddress) external {
        require(hasRole(WHITELISTER_ROLE, _msgSender()), "GameCoin: must have whitelister role");
        _senderWhitelist[whitelistAddress] = true;
        _recipientWhitelist[whitelistAddress] = true;
        emit EventWhiteList(whitelistAddress, true);
    }

    function removeAddressFromWhitelist(address whitelistAddress) external {
        require(hasRole(WHITELISTER_ROLE, _msgSender()), "GameCoin: must have whitelister role");
        _senderWhitelist[whitelistAddress] = false;
        _recipientWhitelist[whitelistAddress] = false;
        emit EventWhiteList(whitelistAddress, false);
    }

    function addAddressToSenderWhitelist(address whitelistAddress) external {
        require(hasRole(WHITELISTER_ROLE, _msgSender()), "GameCoin: must have whitelister role");
        _senderWhitelist[whitelistAddress] = true;
        emit EventWhiteList(whitelistAddress, true);
    }

    function addAddressToRecipientWhitelist(address whitelistAddress) external {
        require(hasRole(WHITELISTER_ROLE, _msgSender()), "GameCoin: must have whitelister role");
        _recipientWhitelist[whitelistAddress] = true;
        emit EventWhiteList(whitelistAddress, true);
    }

    function setBPAddress(address _bp) external {
        require(hasRole(PAUSER_ROLE, _msgSender()), "GameCoin: must have pauser role");
        require(address(BP) == address(0), "Can only be initialized once");
        BP = BotPrevent(_bp);
    }

    function setBPEnabled(bool _enabled) external {
        require(hasRole(PAUSER_ROLE, _msgSender()), "GameCoin: must have pauser role");
        bpEnabled = _enabled;
    }

    function setBotProtectionDisableForever() external {
        require(hasRole(PAUSER_ROLE, _msgSender()), "GameCoin: must have pauser role");
        require(BPDisabledForever == false);
        BPDisabledForever = true;
    }

    /**
     * @dev Pause token transfer, can be used to prevent attack
     *
     */
    function pause() public {
        require(hasRole(PAUSER_ROLE, _msgSender()), "GameCoin: must have pauser role");
        _pause();
    }
    /**
     * @dev Unpause token transfer
     *
     */
    function unpause() public {
        require(hasRole(PAUSER_ROLE, _msgSender()), "GameCoin: must have pauser role");
        _unpause();
    }

    /**
     * @dev Set _beforeTokenTransfer hook to used ERC20Pausable
     *
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20, ERC20Pausable) {
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @dev Moves `amount` of tokens from `sender` to `recipient`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *  Added transfer fee mechanism
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override {
        if (bpEnabled && !BPDisabledForever) {
            BP.protect(sender, recipient, amount);
        }

        if (_senderWhitelist[sender] == true || _recipientWhitelist[recipient] == true) {
            super._transfer(sender, recipient, amount);
        } else {
            // calculate treasury token amount
            uint256 treasury_token_amount = (amount * _transferFeeTreasuryPercent) / 100;
            // burn token only if totalSupply > minimumSupply else put all Fee to treasury
            uint256 burn_token_amount = 0;
            if (totalSupply() > _transferStopBurnWhenLowSupply) {
                burn_token_amount = (amount * _transferFeeBurnPercent) / 100;
            } else {
                treasury_token_amount += (amount * _transferFeeBurnPercent) / 100;
            }
            require(treasury_token_amount + burn_token_amount < amount, "ERC20 Deflationary: transfer fee is greater or equal than amount");
            // treasury token
            super._transfer(sender, _treasuryAddress, treasury_token_amount);
            // burn token
            if (burn_token_amount > 0) {
                _burn(sender, burn_token_amount);
            }
            // adjust amount of recipient
            amount -= treasury_token_amount + burn_token_amount;
            super._transfer(sender, recipient, amount);
        }
    }
}
