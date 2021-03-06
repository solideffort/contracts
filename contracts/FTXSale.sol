pragma solidity ^0.4.18;

import './math/SafeMath.sol';
import "./ownership/Ownable.sol";
import "./Pausable.sol";
import "./FTXPrivatePresale.sol";
import "./FTXPublicPresale.sol";

/*
    Minimum goal aleady reached.
*/
contract FTXSale is Ownable, Pausable {
    using SafeMath for uint256;

    string public constant NAME = "FintruX token sale";
    string public constant VERSION = "0.8";

    FTXPrivatePresale privatePresale;
    FTXPublicPresale publicPresale;

    // this multi-sig address will be replaced on production:
    address public constant FINTRUX_WALLET = 0x7c05c62ae365E88221B62cA41D6eb087fDAa2020;

    uint256 public startDate = 1518022800;                                          // Feb 7, 2017 5:00 PM UTC
    uint256 public endDate = 1519837200;                                            // Feb 28, 2017 5:00 PM UTC

    uint256 public eth2usdRate = 1151;                                              // assume 1ETH = USD$1151 and expect update
    uint256 public maxEthInWei = 1000*10**18;                                       // maximum wei per transaction allowed; 0 means no limit
    uint256 public autoMaxEthInWei = 5*10**18;                                      // limit wei per transaction when MAXIMUM_CAP reach
	
    struct TokenDiscount {
		uint256 tokensAvail;                                                        // total tokens available at this price
		uint256 tokensSold;                                                         // tokens sold at this price
		uint256 tokenPrice;                                                         // number of tokens per ETH
	}
	TokenDiscount[5] public tokenDiscount;

    uint256 public weiRaised = 0;                                                   // total amount of Ether raised in wei
    uint256 public purchaserCount = 0;                                              // total number of purchasers purchased FTX
    uint256 public tokensSold = 0;                                                  // total number of FTX tokens sold
    uint256 public numWhitelisted = 0;                                              // total number whitelisted 

    uint256 public constant TOKEN_HARD_CAP = 75000000 * 10**18;                     // hardcap is 75% of all tokens
    uint256 public constant MIN_PURCHASE = 10**17;                                  // minimum purchase is 0.1 ETH to make the gas worthwhile
    uint256 public constant MIN_FTX_PURCHASE = 150 * 10**18;                        // minimum token purchase is 150 or 0.1 ETH
    uint256 public constant MAXIMUM_CAP = 20000000 * 10**18;                        // lower maximum per transaction when USD$20M in wei is reached
    uint256 public constant ABSOLUTE_CAP = 25000000 * 10**18;                       // absolute maximum raised USD$25M * wei

    uint256 public presaleTokensSold = 0;                                           // number of FTX tokens sold in presales
    uint256 public presaleWeiRaised = 0;

    bool public isFinalized = false;                                                // it becomes true when token sale is completed
    bool public maxCapReached = false;                                              // it becomes true when maximum-cap is reached
    bool public targetCapReached = false;                                           // it becomes true when target-cap is reached
    bool public absoluteCapReached = false;                                         // it becomes true when absolute-cap is reached

    /** the amount of ETH in wei each address has purchased in this crowdsale */
    mapping (address => uint256) public purchasedAmountOf;

    /** the amount of tokens this crowdsale has credited for each purchaser address */
    mapping (address => uint256) public tokenAmountOf;

    address[] public purchasers;                                                     // purchaser wallets

    // list of addresses that can purchase
    mapping (address => bool) public whitelist;

    uint256 public contractTimestamp;
    /**
    * event for token purchase logging
    * @param purchaser who paid for the tokens
    * @param value weis paid for purchase
    * @param amount amount of tokens purchased
    */ 
    event TokenPurchase(address indexed purchaser, uint256 value, uint256 amount);
    
    event Finalized();                                                              // event logging for token sale finalized
    event MaximumCapReached();                                                      // event logging for maximum-cap reached
    event TargetCapReached();                                                       // event logging for target-cap reached
    event AbsoluteCapReached();                                                     // event logging for absolute-cap reached
    event FundsTransferred();                                                       // event logging for funds transfered to FintruX multi-sig wallet
    event Refunded(address indexed beneficiary, uint256 weiAmount);                 // event logging for each individual refunded amount

    /*
        Constructor to initialize everything.
    */
    function FTXSale (address _privatePresale, address _publicPresale, address _owner) public {
        if (_owner == address(0)) {
            _owner = msg.sender;
        }
        require(_privatePresale != address(0));
        require(_publicPresale != address(0));
        require(_owner != address(0));                
        owner = _owner;                                                             // default owner
 
        privatePresale = FTXPrivatePresale(_privatePresale);
        publicPresale = FTXPublicPresale(_publicPresale);
        // initialize to number of FTX sold in all presales
        presaleTokensSold = publicPresale.privatePresaleTokensSold() + publicPresale.publicPresaleTokensSold();
        presaleWeiRaised = publicPresale.weiRaised();                               // initialize to wei raised in public presale
        purchaserCount = publicPresale.purchaserCount();                            // initialize to all presales purchaser count
        tokensSold = presaleTokensSold;                                             // initialize to FTX sold in all presales
        weiRaised = presaleWeiRaised;                                               // initialize to wei raised in all presales
        numWhitelisted = publicPresale.numWhitelisted();

        // bonus tiers
        tokenDiscount[0] = TokenDiscount(3150000 * 10**18, 0, 1575);                // 5.0% bonus
        tokenDiscount[1] = TokenDiscount(5383000 * 10**18, 0, 1538);                // 2.5% bonus
        tokenDiscount[2] = TokenDiscount(10626000 * 10**18, 0, 1518);               // 1.2% bonus
        tokenDiscount[3] = TokenDiscount(18108000 * 10**18, 0, 1509);               // 0.6% bonus
        tokenDiscount[4] = TokenDiscount(37733000 * 10**18, 0, 1500);               // base price

        contractTimestamp = block.timestamp;
    }
    
    /* 
        Make sure FINTRUX_WALLET account is accessible before we accept ether from the public.
    */
    function verifyWalletAddress() external payable {
        require(msg.sender == FINTRUX_WALLET);
        require(msg.value > 0);
        FINTRUX_WALLET.transfer(msg.value);
    }

    /*
        Allow change to auto maximum purchase limit. 0 means no limit.
    */
    function setAutoMaxEthInWei(uint256 ethInWei) external onlyOwner {
        require(ethInWei == 0 || ethInWei >= 10**18);
        autoMaxEthInWei = ethInWei;
    }

    /*
        Allow change to maximum purchase limit anyway in case of error input. 0 means no limit.
    */
    function setMaxEthInWei(uint256 ethInWei) external onlyOwner {
        require(ethInWei == 0 || ethInWei >= 10**18);
        maxEthInWei = ethInWei;
    }

    /*
        Allow changes for crowdsale dates for testing as well as unforseen changes.
    */
    function setDates(uint256 newStartDate, uint256 newEndDate) external onlyOwner {
        startDate = newStartDate;
        endDate = newEndDate;
    }
    
    /*
        Allow ETH to USD rate to be updated by DAPP. Only endDate is affected and endDate can be reset if error found.
    */
    function setETH2USD(uint256 _newRate) external onlyOwner {
        require(_newRate >= 10 && _newRate <= 10000);                                // within reasonable rate.
        eth2usdRate = _newRate;
    }

    /*
        add the ether address to whitelist to enable purchase of token.
    */
    function addToWhitelist(address buyer) external onlyOwner {
        require(buyer != address(0));
        require(!isWhitelisted(buyer));

        whitelist[buyer] = true;
        numWhitelisted += 1;
    }

    /*
        remove the ether address from whitelist in case a mistake was made.
    */
    function delFrWhitelist(address buyer) external onlyOwner {
        require(buyer != address(0));                                               // Valid address
        require(purchasedAmountOf[buyer] <= 0);                                     // No purchase yet.
        require(whitelist[buyer]);

        delete whitelist[buyer];
        numWhitelisted -= 1;
    }
    
    // return true if buyer is whitelisted
    function isWhitelisted(address buyer) public view returns (bool) {
        return whitelist[buyer] || privatePresale.isWhitelisted(buyer) || publicPresale.isWhitelisted(buyer);
    }

    /*
        perform crowdsale.
    */
    function purchaseCrowdsale() internal {
        uint256 amountTransfered = msg.value; 
        uint256 tokens = 0;
        uint256 currentRate = 0;
        uint256 tokensToBuy;

        // Five tiers of discount:
        for (uint di = 0; di < tokenDiscount.length; di++) {
            TokenDiscount storage ts = tokenDiscount[di];

            // if there are tokens available at that tier and still have leftover ETH
            if (ts.tokensSold < ts.tokensAvail && amountTransfered > 0) {
                tokensToBuy = SafeMath.cei(amountTransfered * ts.tokenPrice, 10**18);   // Round up to the nearest token
                if (ts.tokensSold + tokensToBuy > ts.tokensAvail) {
                    tokensToBuy = ts.tokensAvail - ts.tokensSold;
                }
                currentRate = ts.tokenPrice;                                            // current rate FTX per ETH
                tokens += tokensToBuy;                                                  // acumulated tokens to buy
                ts.tokensSold += tokensToBuy;
                amountTransfered -= tokensToBuy / ts.tokenPrice;
            }
        }
        processSale(tokens, currentRate);                                               // process crowdsale at determined price

        // Lower maximum per transaction when USD$20M in wei is reached.
        if (!maxCapReached && weiRaised * eth2usdRate >= MAXIMUM_CAP) {
            maxCapReached = true;                                                       // max-cap has been reached
            maxEthInWei = autoMaxEthInWei;                                              // forced to preset limit
            MaximumCapReached();                                                        // signal the event for communication
        }

        // End the sale immediately if absolute cap has been reached.
        if (!absoluteCapReached && weiRaised * eth2usdRate >= ABSOLUTE_CAP) {
            absoluteCapReached = true;                                                  // absolute-cap has been reached
            endDate = now;                                                              // end the crowdsale cycle
            AbsoluteCapReached();                                                       // signal the event for communication
        }
    }

    /*
        process sale at determined price.
    */
    function processSale(uint256 ftx, uint256 ftxRate) internal {
        uint256 ftxOver = 0;
        uint256 excessEthInWei = 0;
        uint256 paidValue = msg.value;

        if (tokensSold + ftx > TOKEN_HARD_CAP) {                                    // if maximum is exceeded
            ftxOver = tokensSold + ftx - TOKEN_HARD_CAP;                            // find overage
            excessEthInWei = ftxOver/ftxRate;                                       // overage ETH to refund
            ftx = ftx - ftxOver;                                                    // adjust tokens purchased
            paidValue = paidValue - excessEthInWei;                                 // adjust Ether paid
        }
        if (tokenAmountOf[msg.sender] == 0 && privatePresale.tokenAmountOf(msg.sender) == 0 && publicPresale.tokenAmountOf(msg.sender) == 0) {
            purchaserCount++;                                                       // count new purchasers
            purchasers.push(msg.sender);
        }
        tokenAmountOf[msg.sender] = tokenAmountOf[msg.sender].add(ftx);                 // record FTX on purchaser account
        purchasedAmountOf[msg.sender] = purchasedAmountOf[msg.sender].add(paidValue);   // record ETH paid
        weiRaised += paidValue;                                                         // total ETH raised
        tokensSold += ftx;                                                              // total FTX sold
        TokenPurchase(msg.sender, paidValue, ftx);                                      // signal the event for communication
        // transfer must be done at the end after all states are updated to prevent reentrancy attack.
        if (excessEthInWei > 0) {
            msg.sender.transfer(excessEthInWei);                                        // refund overage ETH
            Refunded(msg.sender, excessEthInWei);                                       // signal the event for communication
        }
    }

    /*
       default function to buy tokens.
    */
    function () payable public whenNotPaused {
        require(msg.sender != address(0));                                          // stop if address not valid
        require(isCrowdsale());                                                     // stop if not in sales period
        require(!hasSoldOut());                                                     // stop if no more token to sell
        require(msg.value >= MIN_PURCHASE);                                         // stop if the purchase is too small
        require(isWhitelisted(msg.sender));                                         // no purchase unless whitelisted
        require(maxEthInWei == 0 || msg.value <= maxEthInWei);                      // not exceeding per transaction limit set
        purchaseCrowdsale();                                                        // do crowdsale
    }

    /*
        Check to see if this is crowdsale.
    */
    function isCrowdsale() public view returns (bool) {
        return !isFinalized && now >= startDate && now <= endDate;
    }

    /*
        Check to see if the crowdsale end date has passed or if all tokens allocated for sale has been purchased.
    */
    function hasEnded() public view returns (bool) {
        return now > endDate || (TOKEN_HARD_CAP - tokensSold < MIN_FTX_PURCHASE);
    }

    /*
        check if allocated has sold out.
    */
    function hasSoldOut() public view returns (bool) {
        return TOKEN_HARD_CAP - tokensSold < MIN_FTX_PURCHASE;
    }

    /*
        Called after crowdsale ends, to do some extra finalization work.
    */
    function finalize() public onlyOwner {
        require(!isFinalized);                                                      // do nothing if finalized
        require(hasEnded());                                                        // crowdsale must have ended
        isFinalized = true;                                                         // mark as finalized
        FINTRUX_WALLET.transfer(this.balance);                                      // transfer to FintruX multisig wallet
        FundsTransferred();                                                         // signal the event for communication
        Finalized();                                                                // signal the event for communication
    }

    /*
        Corwdsale Dapp calls these helper functions.
    */
    function isSaleActive() public view returns (bool) {
        return isCrowdsale() && !hasEnded();                                // return true if sales is on
    }

    /*
        For the convenience of crowdsale interface to find current discount tier.
    */
    function getTier() public view returns (uint256) {
        uint256 tier = 1;                                                           // Assume presale top tier discount
        for (uint di = 0; di < tokenDiscount.length; di++) {
            TokenDiscount storage ts = tokenDiscount[di];
            if (ts.tokensSold < ts.tokensAvail && tier == 1) {
                tier = di + 3;                                                      // 3 means tier 1 for crowdsale
            }
        }
        return tier;
    }

    /*
        For the convenience of crowdsale interface to present status info.
    */
    function getCrowdSaleStatus() public view returns(uint256[3]) {
        // 0 - presale not started
        // 1 - private presale started
        // 2 - private presale ended, public presale not started
        // 3 - presale started (public)
        // 4 - presale ended (private/public), crowsale not started
        // 5 - crowsale started
        // 6 - crowsale ended
        if (now < startDate) {
            return([4,startDate,endDate]);
        } else if (now <= endDate && !hasEnded()) {
            return([5,startDate,endDate]);
        } else {
            return([6,startDate,endDate]);
        }
    }
    
    function getPurchaserLength() public constant returns(uint256 length) {
        return purchasers.length;
    }
}