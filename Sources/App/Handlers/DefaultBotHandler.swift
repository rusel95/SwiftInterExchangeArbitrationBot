//
//  DefaultBotHandler.swift
//  
//
//  Created by Ruslan Popesku on 22.06.2022.
//

import Vapor
import telegram_vapor_bot
import Logging
import CoreFoundation

struct Request: Encodable {
    
    enum Method: String, Encodable {
        case subscribe = "SUBSCRIBE"
        case unsubscribe = "UNSUBSCRIBE"
    }
    
    let method: Method
    let params: [String]
    let id: UInt
}

struct TradeableSymbolOrderbookDepth: Codable {
    
    let tradeableSymbol: BinanceAPIService.Symbol
    let orderbookDepth: OrderbookDepth
    
}

final class DefaultBotHandlers {
    
    // MARK: - PROPERTIES
    
    private var logger = Logger(label: "handlers.logger")

    private let bot: TGBotPrtcl
    private let app: Application
    private let emailService: EmailService
    
    // MARK: - METHODS
    
    init(bot: TGBotPrtcl, app: Application) {
        self.bot = bot
        self.app = app
        self.emailService = EmailService(app: app)
        
        Task {
            let allSymbols =  try await BinanceAPIService().getExchangeInfo()
            
            let tradeableSymbols = allSymbols.filter { $0.status == .trading && $0.isSpotTradingAllowed }
            
            await withTaskGroup(of: (symbol: BinanceAPIService.Symbol, depth: OrderbookDepth?).self) { group in
                for tradeableSymbol in tradeableSymbols {
                    group.addTask {
                        let orderboolDepth = try? await BinanceAPIService.shared.getOrderbookDepth(symbol: tradeableSymbol.symbol, limit: 10)
                        return (tradeableSymbol, orderboolDepth)
                    }
                }
                for await tuple in group {
                    guard let depth = tuple.depth else { return }
                    
                    TradeableSymbolOrderbookDepthsStorage.shared.tradeableSymbolOrderbookDepths[tuple.symbol.symbol] = TradeableSymbolOrderbookDepth(tradeableSymbol: tuple.symbol, orderbookDepth: depth)
                }
            }
            
            let priceChangeStatisticElements = try await BinanceAPIService.shared.getPriceChangeStatistics()
            let bookTickers = try await BinanceAPIService.shared.getAllBookTickers()
            PriceChangeStatisticStorage.shared.setTradingVolumeStableEquivalent(
                priceChangeStatistics: priceChangeStatisticElements,
                bookTickers: bookTickers,
                symbols: allSymbols
            )
        }
    }
    
    func addHandlers(app: Vapor.Application) {
        commandStartHandler(app: app, bot: bot)
        commandStartAlertingHandler(app: app, bot: bot)
        commandStopHandler(app: app, bot: bot)
        commandTestHandler(app: app, bot: bot)
    }

}

// MARK: - HANDLERS

private extension DefaultBotHandlers {
    
    // MARK: /start
    
    func commandStartHandler(app: Vapor.Application, bot: TGBotPrtcl) {
        let handler = TGCommandHandler(commands: ["/start"]) { update, bot in
            guard let chatId = update.message?.chat.id else { return }
           
            let infoMessage = """
            /start_alerting - mode for alerting about extra opportunities (>= \(0.1)% of profit)
            /stop - all modes are suspended;
            Hope to be useful
            
            While I'm still on development stage, please write to @rusel95 if any questions
            """
            _ = try? bot.sendMessage(params: .init(chatId: .chat(chatId), text: infoMessage))
        }
        bot.connection.dispatcher.add(handler)
    }
    
    // MARK: /start_alerting
    
    func commandStartAlertingHandler(app: Vapor.Application, bot: TGBotPrtcl) {
        let handler = TGCommandHandler(commands: [BotMode.alerting.command]) { update, bot in
            guard let chatId = update.message?.chat.id, let user = update.message?.from else { return }
            
            do {
                let text = "Starting alerting about inter exchange opportunities with >= \(0.1)% profitability"
                _ = try bot.sendMessage(params: .init(chatId: .chat(chatId), text: text))
                UsersInfoProvider.shared.handleModeSelected(chatId: chatId, user: user, mode: .alerting)
            } catch (let botError) {
                print(botError.localizedDescription)
            }
        }
        bot.connection.dispatcher.add(handler)
    }
    
    // MARK: /stop
    
    func commandStopHandler(app: Vapor.Application, bot: TGBotPrtcl) {
        let handler = TGCommandHandler(commands: [BotMode.suspended.command]) { update, bot in
            guard let chatId = update.message?.chat.id else { return }
            
            UsersInfoProvider.shared.handleStopAllModes(chatId: chatId)
            _ = try? bot.sendMessage(params: .init(chatId: .chat(chatId), text: "All processes suspended"))
        }
        bot.connection.dispatcher.add(handler)
    }
    
    // MARK: /status
    
    func commandTestHandler(app: Vapor.Application, bot: TGBotPrtcl) {
        let handler = TGCommandHandler(commands: ["/status"]) { update, bot in
            guard let chatId = update.message?.chat.id else { return }
            
            Task {
                do {
                    var text = UsersInfoProvider.shared.getAllUsersInfo()
                        .map { $0.description }
                        .joined(separator: "\n")
                    
                    if let editParamsArray: [TGEditMessageTextParams] = try? await app.caches.memory.get(
                        "editParamsArray",
                        as: [TGEditMessageTextParams].self
                    ) {
                        text.append("\nTo Update: \(editParamsArray.count)")
                    }
                    
                    text.append("\n\(String().getMemoryUsedMegabytes())")
                  
                    _ = try bot.sendMessage(params: .init(chatId: .chat(chatId), text: text))
                } catch {
                    _ = try bot.sendMessage(params: .init(chatId: .chat(chatId), text: error.localizedDescription))
                }
            }
        }
        bot.connection.dispatcher.add(handler)
    }
    
}
