//
//  PricesUpdaterJob.swift
//  
//
//  Created by Ruslan Popesku on 21.03.2023.
//

import Queues
import Vapor
import CoreFoundation

struct PricesUpdaterJob: ScheduledJob {

    typealias StockEchangeBookTickers = (exchange: StockExchange, bookTickers: [BookTicker])

    private let app: Application
    private let emailService: EmailService

    init(app: Application) {
        self.app = app
        self.emailService = EmailService(app: app)
    }

    func run(context: Queues.QueueContext) -> NIOCore.EventLoopFuture<Void> {
        return context.eventLoop.performWithTask {
            do {
                async let binanceBookTickers: StockEchangeBookTickers = (.binance, try await BinanceAPIService.shared.getAllBookTickers())
                async let whitebitBookTickers: StockEchangeBookTickers = (.whitebit, try await WhiteBitAPIService.shared.getBookTickers())
                async let kucointBookTickers: StockEchangeBookTickers = (.kucoin, try await KuCoinAPIService.shared.getBookTickers())

                let stockExchangesBookTickers: [StockEchangeBookTickers] = try await [binanceBookTickers, whitebitBookTickers, kucointBookTickers]

                let opportunities = findArbitrageOpportunities(stockExchangeBookTickers: stockExchangesBookTickers)

                print(opportunities)
            } catch {
                print(error.localizedDescription)
                emailService.sendEmail(
                    subject: "[price statistic]",
                    text: error.localizedDescription
                )
            }
        }
    }

}

struct ArbitrageOpportunity {
    let buyExchange: StockExchange
    let sellExchange: StockExchange
    let symbol: String
    let buyPrice: Double
    let sellPrice: Double
    let profitPercentage: Double
}

private extension PricesUpdaterJob {

    // Have to compare tradeable symbols prices for all tickers for several marketplaces
    // - return: profitable opportunities array
    func findArbitrageOpportunities(stockExchangeBookTickers: [StockEchangeBookTickers]) -> [ArbitrageOpportunity] {
        let calcStartTime = CFAbsoluteTimeGetCurrent()
        var opportunities: [ArbitrageOpportunity] = []

        // Get a unique list of trading pairs
        let uniqueSymbols = Set(stockExchangeBookTickers.flatMap { $0.bookTickers.map { $0.symbol } })

        for symbol in uniqueSymbols {
            var bookTickersForSymbol: [BookTicker] = []

            for stockExchangeBookTicker in stockExchangeBookTickers {
                bookTickersForSymbol.append(contentsOf: stockExchangeBookTicker.bookTickers.filter { $0.symbol == symbol })
            }

            guard bookTickersForSymbol.count > 1 else { continue }

            let sortedAsks = bookTickersForSymbol.sorted { $0.buyPrice! < $1.buyPrice! }
            let sortedBids = bookTickersForSymbol.sorted { $0.sellPrice! > $1.sellPrice! }

            let lowestAsk = sortedAsks.first!
            let highestBid = sortedBids.first!

            let buyExchange = stockExchangeBookTickers.first(where: { $0.bookTickers.contains(where: { $0.symbol == lowestAsk.symbol }) })!.exchange
            let sellExchange = stockExchangeBookTickers.first(where: { $0.bookTickers.contains(where: { $0.symbol == highestBid.symbol }) })!.exchange


            if highestBid.sellPrice! > lowestAsk.buyPrice! && buyExchange != sellExchange {
                let profitPercentage = (highestBid.sellPrice! - lowestAsk.buyPrice!) / lowestAsk.buyPrice! * 100

                let opportunity = ArbitrageOpportunity(
                    buyExchange: buyExchange,
                    sellExchange: sellExchange,
                    symbol: symbol,
                    buyPrice: lowestAsk.buyPrice!,
                    sellPrice: highestBid.sellPrice!,
                    profitPercentage: profitPercentage
                )

                opportunities.append(opportunity)
            }
        }

        print(String(format: "%.4f", CFAbsoluteTimeGetCurrent() - calcStartTime))
        return opportunities
    }

}
