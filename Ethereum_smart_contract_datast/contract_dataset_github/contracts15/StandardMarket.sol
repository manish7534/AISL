pragma solidity ^0.5.0;
import "../Markets/Market.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/drafts/SignedSafeMath.sol";
import "../Events/Event.sol";
import "../MarketMakers/MarketMaker.sol";


contract StandardMarketData {
    /*
     *  Constants
     */
    uint24 public constant FEE_RANGE = 1000000; // 100%
}

contract StandardMarketProxy is Proxy, MarketData, StandardMarketData {
    constructor(address proxy, address _creator, Event _eventContract, MarketMaker _marketMaker, uint24 _fee)
        Proxy(proxy)
        public
    {
        // Validate inputs
        require(address(_eventContract) != address(0) && address(_marketMaker) != address(0) && _fee < FEE_RANGE);
        creator = _creator;
        createdAtBlock = block.number;
        eventContract = _eventContract;
        netOutcomeTokensSold = new int[](eventContract.getOutcomeCount());
        fee = _fee;
        marketMaker = _marketMaker;
        stage = Stages.MarketCreated;
    }
}

/// @title Standard market contract - Backed implementation of standard markets
/// @author Stefan George - <stefan@gnosis.pm>
contract StandardMarket is Proxied, Market, StandardMarketData {
    using SignedSafeMath for int;
    using SafeMath for uint;

    /*
     *  Modifiers
     */
    modifier isCreator() {
        // Only creator is allowed to proceed
        require(msg.sender == creator);
        _;
    }

    modifier atStage(Stages _stage) {
        // Contract has to be in given stage
        require(stage == _stage);
        _;
    }

    /*
     *  Public functions
     */
    /// @dev Allows to fund the market with collateral tokens converting them into outcome tokens
    /// @param _funding Funding amount
    function fund(uint _funding)
        public
        isCreator
        atStage(Stages.MarketCreated)
    {
        // Request collateral tokens and allow event contract to transfer them to buy all outcomes
        require(   eventContract.collateralToken().transferFrom(msg.sender, address(this), _funding)
                && eventContract.collateralToken().approve(address(eventContract), _funding));
        eventContract.buyAllOutcomes(_funding);
        funding = _funding;
        stage = Stages.MarketFunded;
        emit MarketFunding(funding);
    }

    /// @dev Allows market creator to close the markets by transferring all remaining outcome tokens to the creator
    function close()
        public
        isCreator
        atStage(Stages.MarketFunded)
    {
        uint8 outcomeCount = eventContract.getOutcomeCount();
        for (uint8 i = 0; i < outcomeCount; i++)
            require(eventContract.outcomeTokens(i).transfer(creator, eventContract.outcomeTokens(i).balanceOf(address(this))));
        stage = Stages.MarketClosed;
        emit MarketClosing();
    }

    /// @dev Allows market creator to withdraw fees generated by trades
    /// @return Fee amount
    function withdrawFees()
        public
        isCreator
        returns (uint fees)
    {
        fees = eventContract.collateralToken().balanceOf(address(this));
        // Transfer fees
        require(eventContract.collateralToken().transfer(creator, fees));
        emit FeeWithdrawal(fees);
    }

    /// @dev Allows to buy outcome tokens from market maker
    /// @param outcomeTokenIndex Index of the outcome token to buy
    /// @param outcomeTokenCount Amount of outcome tokens to buy
    /// @param maxCost The maximum cost in collateral tokens to pay for outcome tokens
    /// @return Cost in collateral tokens
    function buy(uint8 outcomeTokenIndex, uint outcomeTokenCount, uint maxCost)
        public
        atStage(Stages.MarketFunded)
        returns (uint cost)
    {
        require(int(outcomeTokenCount) >= 0 && int(maxCost) > 0);
        uint8 outcomeCount = eventContract.getOutcomeCount();
        require(outcomeTokenIndex >= 0 && outcomeTokenIndex < outcomeCount);
        int[] memory outcomeTokenAmounts = new int[](outcomeCount);
        outcomeTokenAmounts[outcomeTokenIndex] = int(outcomeTokenCount);
        (int netCost, int outcomeTokenNetCost, uint fees) = tradeImpl(outcomeCount, outcomeTokenAmounts, int(maxCost));
        require(netCost >= 0 && outcomeTokenNetCost >= 0);
        cost = uint(netCost);
        emit OutcomeTokenPurchase(msg.sender, outcomeTokenIndex, outcomeTokenCount, uint(outcomeTokenNetCost), fees);
    }

    /// @dev Allows to sell outcome tokens to market maker
    /// @param outcomeTokenIndex Index of the outcome token to sell
    /// @param outcomeTokenCount Amount of outcome tokens to sell
    /// @param minProfit The minimum profit in collateral tokens to earn for outcome tokens
    /// @return Profit in collateral tokens
    function sell(uint8 outcomeTokenIndex, uint outcomeTokenCount, uint minProfit)
        public
        atStage(Stages.MarketFunded)
        returns (uint profit)
    {
        require(-int(outcomeTokenCount) <= 0 && -int(minProfit) < 0);
        uint8 outcomeCount = eventContract.getOutcomeCount();
        require(outcomeTokenIndex >= 0 && outcomeTokenIndex < outcomeCount);
        int[] memory outcomeTokenAmounts = new int[](outcomeCount);
        outcomeTokenAmounts[outcomeTokenIndex] = -int(outcomeTokenCount);
        (int netCost, int outcomeTokenNetCost, uint fees) = tradeImpl(outcomeCount, outcomeTokenAmounts, -int(minProfit));
        require(netCost <= 0 && outcomeTokenNetCost <= 0);
        profit = uint(-netCost);
        emit OutcomeTokenSale(msg.sender, outcomeTokenIndex, outcomeTokenCount, uint(-outcomeTokenNetCost), fees);
    }

    /// @dev Buys all outcomes, then sells all shares of selected outcome which were bought, keeping
    ///      shares of all other outcome tokens.
    /// @param outcomeTokenIndex Index of the outcome token to short sell
    /// @param outcomeTokenCount Amount of outcome tokens to short sell
    /// @param minProfit The minimum profit in collateral tokens to earn for short sold outcome tokens
    /// @return Cost to short sell outcome in collateral tokens
    function shortSell(uint8 outcomeTokenIndex, uint outcomeTokenCount, uint minProfit)
        public
        returns (uint cost)
    {
        // Buy all outcomes
        require(   eventContract.collateralToken().transferFrom(msg.sender, address(this), outcomeTokenCount)
                && eventContract.collateralToken().approve(address(eventContract), outcomeTokenCount));
        eventContract.buyAllOutcomes(outcomeTokenCount);
        // Short sell selected outcome
        eventContract.outcomeTokens(outcomeTokenIndex).approve(address(this), outcomeTokenCount);
        uint profit = this.sell(outcomeTokenIndex, outcomeTokenCount, minProfit);
        cost = outcomeTokenCount - profit;
        // Transfer outcome tokens to buyer
        uint8 outcomeCount = eventContract.getOutcomeCount();
        for (uint8 i = 0; i < outcomeCount; i++)
            if (i != outcomeTokenIndex)
                require(eventContract.outcomeTokens(i).transfer(msg.sender, outcomeTokenCount));
        // Send change back to buyer
        require(eventContract.collateralToken().transfer(msg.sender, profit));
        emit OutcomeTokenShortSale(msg.sender, outcomeTokenIndex, outcomeTokenCount, cost);
    }

    /// @dev Allows to trade outcome tokens and collateral with the market maker
    /// @param outcomeTokenAmounts Amounts of each outcome token to buy or sell. If positive, will buy this amount of outcome token from the market. If negative, will sell this amount back to the market instead.
    /// @param collateralLimit If positive, this is the limit for the amount of collateral tokens which will be sent to the market to conduct the trade. If negative, this is the minimum amount of collateral tokens which will be received from the market for the trade. If zero, there is no limit.
    /// @return If positive, the amount of collateral sent to the market. If negative, the amount of collateral received from the market. If zero, no collateral was sent or received.
    function trade(int[] memory outcomeTokenAmounts, int collateralLimit)
        public
        atStage(Stages.MarketFunded)
        returns (int netCost)
    {
        uint8 outcomeCount = eventContract.getOutcomeCount();
        require(outcomeTokenAmounts.length == outcomeCount);

        int outcomeTokenNetCost;
        uint fees;
        (netCost, outcomeTokenNetCost, fees) = tradeImpl(outcomeCount, outcomeTokenAmounts, collateralLimit);

        emit OutcomeTokenTrade(msg.sender, outcomeTokenAmounts, outcomeTokenNetCost, fees);
    }

    function tradeImpl(uint8 outcomeCount, int[] memory outcomeTokenAmounts, int collateralLimit)
        private
        returns (int netCost, int outcomeTokenNetCost, uint fees)
    {
        // Calculate net cost for executing trade
        outcomeTokenNetCost = marketMaker.calcNetCost(this, outcomeTokenAmounts);
        if(outcomeTokenNetCost < 0)
            fees = calcMarketFee(uint(-outcomeTokenNetCost));
        else
            fees = calcMarketFee(uint(outcomeTokenNetCost));

        require(int(fees) >= 0);
        netCost = outcomeTokenNetCost.add(int(fees));

        require(
            (collateralLimit != 0 && netCost <= collateralLimit) ||
            collateralLimit == 0
        );

        if(outcomeTokenNetCost > 0) {
            require(
                eventContract.collateralToken().transferFrom(msg.sender, address(this), uint(netCost)) &&
                eventContract.collateralToken().approve(address(eventContract), uint(outcomeTokenNetCost))
            );

            eventContract.buyAllOutcomes(uint(outcomeTokenNetCost));
        }

        for (uint8 i = 0; i < outcomeCount; i++) {
            if(outcomeTokenAmounts[i] != 0) {
                if(outcomeTokenAmounts[i] < 0) {
                    require(eventContract.outcomeTokens(i).transferFrom(msg.sender, address(this), uint(-outcomeTokenAmounts[i])));
                } else {
                    require(eventContract.outcomeTokens(i).transfer(msg.sender, uint(outcomeTokenAmounts[i])));
                }

                netOutcomeTokensSold[i] = netOutcomeTokensSold[i].add(outcomeTokenAmounts[i]);
            }
        }

        if(outcomeTokenNetCost < 0) {
            // This is safe since
            // 0x8000000000000000000000000000000000000000000000000000000000000000 ==
            // uint(-int(-0x8000000000000000000000000000000000000000000000000000000000000000))
            eventContract.sellAllOutcomes(uint(-outcomeTokenNetCost));
            if(netCost < 0) {
                require(eventContract.collateralToken().transfer(msg.sender, uint(-netCost)));
            }
        }
    }

    /// @dev Calculates fee to be paid to market maker
    /// @param outcomeTokenCost Cost for buying outcome tokens
    /// @return Fee for trade
    function calcMarketFee(uint outcomeTokenCost)
        public
        view
        returns (uint)
    {
        return outcomeTokenCost * fee / FEE_RANGE;
    }
}
