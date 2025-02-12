//
// NotificationService.swift
//
// Siskin IM
// Copyright (C) 2019 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import BackgroundTasks
import UserNotifications
import Shared
import TigaseSwift
import os.log

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)? {
        didSet {
            debug("content handler set!");
        }
    }
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        
        debug("Received push!");
        if let bestAttemptContent = bestAttemptContent {
            bestAttemptContent.sound = UNNotificationSound.default;
            bestAttemptContent.categoryIdentifier = "MESSAGE";

            if let account = BareJID(bestAttemptContent.userInfo["account"] as? String) {
                DispatchQueue.main.async {
                    NotificationManager.instance.initialize(provider: ExtensionNotificationManagerProvider());
                    self.debug("push for account:", account);
                    if let encryped = bestAttemptContent.userInfo["encrypted"] as? String, let ivStr = bestAttemptContent.userInfo["iv"] as? String {
                        if let key = NotificationEncryptionKeys.key(for: account), let data = Data(base64Encoded: encryped), let iv = Data(base64Encoded: ivStr) {
                            self.debug("got encrypted push with known key");
                            let cipher = Cipher.AES_GCM();
                            var decoded = Data();
                            if cipher.decrypt(iv: iv, key: key, encoded: data, auth: nil, output: &decoded) {
                                self.debug("got decrypted data:", String(data: decoded, encoding: .utf8) as Any);
                                if let payload = try? JSONDecoder().decode(Payload.self, from: decoded) {
                                    self.debug("decoded payload successfully!");
                                    NotificationManager.instance.prepareNewMessageNotification(content: bestAttemptContent, account: account, sender: payload.sender.bareJid, type: payload.type, nickname: payload.nickname, body: payload.message, completionHandler: { content in
                                        DispatchQueue.main.async {
                                            contentHandler(content);
                                        }
                                    });
                                    return;
                                }
                            }
                        }
                        contentHandler(bestAttemptContent)
                    } else {
                        self.debug("got plain push with", bestAttemptContent.userInfo[AnyHashable("sender")] as? String as Any, bestAttemptContent.userInfo[AnyHashable("body")] as? String as Any, bestAttemptContent.userInfo[AnyHashable("unread-messages")] as? Int as Any, bestAttemptContent.userInfo[AnyHashable("nickname")] as? String as Any);
                        NotificationManager.instance.prepareNewMessageNotification(content: bestAttemptContent, account: account, sender: JID(bestAttemptContent.userInfo[AnyHashable("sender")] as? String)?.bareJid, type: .unknown, nickname: bestAttemptContent.userInfo[AnyHashable("nickname")] as? String, body: bestAttemptContent.userInfo[AnyHashable("body")] as? String, completionHandler: { content in
                            DispatchQueue.main.async {
                                contentHandler(content);
                            }
                        });
                    }
                }
                return;
            } else {
                contentHandler(bestAttemptContent);
            }
        } else {
            contentHandler(request.content);
        }
//        if #available(iOS 13.0, *) {
//            let taskRequest = BGAppRefreshTaskRequest(identifier: "org.tigase.messenger.mobile.refresh");
//            taskRequest.earliestBeginDate = nil
//            do {
//                debug("scheduling background app refresh")
//                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "org.tigase.messenger.mobile.refresh")
//                try BGTaskScheduler.shared.submit(taskRequest);
//            } catch {
//                debug("Could not schedule app refresh: \(error)")
//            }
//        }
    }
    
//    func updateNotification(content: UNMutableNotificationContent, account: BareJID, unread: Int, sender: JID, type kind: Payload.Kind, nickname: String?, body: String) {
//        let tmp = try! DBConnection.main.prepareStatement(NotificationService.GET_NAME_QUERY).findFirst(["account": account, "jid": sender.bareJid] as [String: Any?], map: { (cursor) -> (String?, Int)? in
//            return (cursor["name"], cursor["type"]!);
//        });
//        let name = tmp?.0;
//        let type: Payload.Kind = tmp?.1 == 1 ? .groupchat : .chat;
//        switch type {
//        case .chat:
//            content.title = name ?? sender.stringValue;
//            content.body = body;
//            content.userInfo = ["account": account.stringValue, "sender": sender.bareJid.stringValue];
//        case .groupchat:
//            if let nickname = nickname {
//                content.title = "\(nickname) mentioned you in \(name ?? sender.bareJid.stringValue)";
//            } else {
//                content.title = "\(name ?? sender.bareJid.stringValue)";
//            }
//            content.body = body;
//            content.userInfo = ["account": account.stringValue, "sender": sender.bareJid.stringValue];
//        default:
//            break;
//        }
//        content.categoryIdentifier = NotificationCategory.MESSAGE.rawValue;
//        //content.badge = 2;
//
//    }
    
    func debug(_ data: Any...) {
        os_log("%{public}@", log: OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "SiskinPush"), "\(Date()): \(data)");
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler = contentHandler, let bestAttemptContent =  bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

}

extension DBConnection {
    static func main<T>(execute: @escaping (DBConnection) throws ->T) throws -> T {
        let dbURL = mainDbURL();
        let connection = try DBConnection.init(dbPath: dbURL!.path);
        return try execute(connection);
    }
}

class ExtensionNotificationManagerProvider: NotificationManagerProvider {
    
    static let GET_NAME_QUERY = "select name, 0 as type from roster_items where account = :account and jid = :jid union select name, 1 as type from chats where account = :account and jid = :jid and type > 0 order by type desc";

    static let GET_UNREAD_CHATS = "select c.account, c.jid from chats c inner join chat_history ch where ch.account = c.account and ch.jid = c.jid and ch.state in (2,6,7) group by c.account, c.jid";
    
    func getChatNameAndType(for account: BareJID, with jid: BareJID, completionHandler: @escaping (String?, Payload.Kind) -> Void) {
        let tmp = try? DBConnection.main(execute: { conn in
            return try conn.prepareStatement(ExtensionNotificationManagerProvider.GET_NAME_QUERY).findFirst(["account": account, "jid": jid] as [String: Any?], map: { (cursor) -> (String?, Int)? in
                    return (cursor["name"], cursor["type"]!);
                });
        });
        completionHandler(tmp?.0, tmp?.1 == 0 ? .chat : .groupchat);
    }
    
    func countBadge(withThreadId: String?, completionHandler: @escaping (Int) -> Void) {
        NotificationManager.unreadChatsThreadIds { (result) in
            var unreadChats = result;
            let activeAccounts = self.getActiveAccounts()
            
            try? DBConnection.main(execute: { conn in
                try conn.prepareStatement(ExtensionNotificationManagerProvider.GET_UNREAD_CHATS).query(forEach: { cursor in
                    if let account: BareJID = cursor["account"], let jid: BareJID = cursor["jid"] {
                        if activeAccounts.contains(account) {
                            unreadChats.insert("account=\(account.stringValue)|sender=\(jid.stringValue)")
                        }
                    }
                })
            });
            
            if let threadId = withThreadId {
                unreadChats.insert(threadId);
            }
            
            completionHandler(unreadChats.count);
        }
    }
        
    func shouldShowNotification(account: BareJID, sender: BareJID?, body: String?, completionHandler: @escaping (Bool)->Void) {
        completionHandler(true);
    }
        
    func getActiveAccounts() -> [BareJID] {
        let query = [ String(kSecClass) : kSecClassGenericPassword, String(kSecMatchLimit) : kSecMatchLimitAll, String(kSecReturnAttributes) : kCFBooleanTrue as Any, String(kSecAttrService) : "xmpp" ] as [String : Any];
        var result: CFTypeRef?;
        
        guard SecItemCopyMatching(query as CFDictionary, &result) == noErr else {
            return [];
        }
        
        guard let results = result as? [[String: NSObject]] else {
            return [];
        }
        
        let accounts =  results.map { item -> BareJID in
            return BareJID(item[kSecAttrAccount as String] as! String);
        }.sorted(by: { (j1, j2) -> Bool in
            j1.stringValue.compare(j2.stringValue) == .orderedAscending
        })
        
        return accounts.filter { account in
            let query = getAccountQuery(account.stringValue)
            var result: CFTypeRef?
            
            guard SecItemCopyMatching(query as CFDictionary, &result) == noErr else { return false }
            
            guard let r = result as? [String: NSObject] else { return false }
            
            var dict: [String: Any]? = nil;
            if let data = r[String(kSecAttrGeneric)] as? NSData {
                do {
                    dict = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSDictionary.self, from: data as Data) as? [String : Any]
                } catch {
                    // failed to get account object
                }
            }
            
            if (dict?["active"] as? Bool) ?? false {
                return true
            } else {
                return false
            }
        }
    }
        
    func getAccountQuery(_ name:String, withData:CFString = kSecReturnAttributes) -> [String: Any] {
        return [ String(kSecClass) : kSecClassGenericPassword, String(kSecMatchLimit) : kSecMatchLimitOne, String(withData) : kCFBooleanTrue!, String(kSecAttrService) : "xmpp" as NSObject, String(kSecAttrAccount) : name as NSObject ];
    }
}


