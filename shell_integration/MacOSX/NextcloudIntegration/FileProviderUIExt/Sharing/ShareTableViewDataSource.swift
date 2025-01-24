//
//  ShareTableViewDataSource.swift
//  FileProviderUIExt
//
//  Created by Claudio Cambra on 27/2/24.
//

import AppKit
import FileProvider
import NextcloudKit
import NextcloudFileProviderKit
import NextcloudCapabilitiesKit
import OSLog

class ShareTableViewDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let shareItemViewIdentifier = NSUserInterfaceItemIdentifier("ShareTableItemView")
    private let shareItemViewNib = NSNib(nibNamed: "ShareTableItemView", bundle: nil)
    private let reattemptInterval: TimeInterval = 3.0

    let kit = NextcloudKit.shared

    var uiDelegate: ShareViewDataSourceUIDelegate?
    var sharesTableView: NSTableView? {
        didSet {
            sharesTableView?.register(shareItemViewNib, forIdentifier: shareItemViewIdentifier)
            sharesTableView?.rowHeight = 42.0  // Height of view in ShareTableItemView XIB
            sharesTableView?.dataSource = self
            sharesTableView?.delegate = self
            sharesTableView?.reloadData()
        }
    }
    var capabilities: Capabilities?
    var itemMetadata: NKFile?

    private(set) var itemURL: URL?
    private(set) var itemServerRelativePath: String?
    private(set) var shares: [NKShare] = [] {
        didSet { Task { @MainActor in sharesTableView?.reloadData() } }
    }
    private(set) var account: Account? {
        didSet {
            guard let account = account else { return }
            kit.appendSession(
                account: account.ncKitAccount,
                urlBase: account.serverUrl,
                user: account.username,
                userId: account.username,
                password: account.password,
                userAgent: "Nextcloud-macOS/FileProviderUIExt",
                nextcloudVersion: 25,
                groupIdentifier: ""
            )
        }
    }

    func loadItem(url: URL) {
        itemServerRelativePath = nil
        itemURL = url
        Task {
            await reload()
        }
    }

    func reattempt() {
        DispatchQueue.main.async {
            Timer.scheduledTimer(withTimeInterval: self.reattemptInterval, repeats: false) { _ in
                Task { await self.reload() }
            }
        }
    }

    func reload() async {
        guard let itemURL else {
            presentError("No item URL, cannot reload data!")
            return
        }
        guard let itemIdentifier = await withCheckedContinuation({
            (continuation: CheckedContinuation<NSFileProviderItemIdentifier?, Never>) -> Void in
            NSFileProviderManager.getIdentifierForUserVisibleFile(
                at: itemURL
            ) { identifier, domainIdentifier, error in
                defer { continuation.resume(returning: identifier) }
                guard error == nil else {
                    self.presentError("No item with identifier: \(error.debugDescription)")
                    return
                }
            }
        }) else {
            presentError("Could not get identifier for item, no shares can be acquired.")
            return
        }

        do {
            let connection = try await serviceConnection(url: itemURL, interruptionHandler: {
                Logger.sharesDataSource.error("Service connection interrupted")
            })
            guard let serverPath = await connection.itemServerPath(identifier: itemIdentifier),
                  let credentials = await connection.credentials() as? Dictionary<String, String>,
                  let convertedAccount = Account(dictionary: credentials),
                  !convertedAccount.password.isEmpty
            else {
                presentError("Failed to get details from File Provider Extension. Retrying.")
                reattempt()
                return
            }
            let serverPathString = serverPath as String
            itemServerRelativePath = serverPathString
            account = convertedAccount
            await sharesTableView?.deselectAll(self)
            capabilities = await fetchCapabilities()
            guard capabilities != nil else { return }
            guard capabilities?.filesSharing?.apiEnabled == true else {
                presentError("Server does not support shares.")
                return
            }
            guard let account else {
                presentError("Account data is unavailable, cannot reload data!")
                return
            }
            itemMetadata = await fetchItemMetadata(
                itemRelativePath: serverPathString, account: account, kit: kit
            )
            guard itemMetadata?.permissions.contains("R") == true else {
                presentError("This file cannot be shared.")
                return
            }
            shares = await fetch(
                itemIdentifier: itemIdentifier, itemRelativePath: serverPathString
            )
        } catch let error {
            presentError("Could not reload data: \(error), will try again.")
            reattempt()
        }
    }

    private func fetch(
        itemIdentifier: NSFileProviderItemIdentifier, itemRelativePath: String
    ) async -> [NKShare] {
        Task { @MainActor in uiDelegate?.fetchStarted() }
        defer { Task { @MainActor in uiDelegate?.fetchFinished() } }

        let rawIdentifier = itemIdentifier.rawValue
        Logger.sharesDataSource.info("Fetching shares for item \(rawIdentifier, privacy: .public)")

        guard let account else {
            self.presentError("NextcloudKit instance or account is unavailable, cannot fetch shares!")
            return []
        }

        let parameter = NKShareParameter(path: itemRelativePath)

        return await withCheckedContinuation { continuation in
            kit.readShares(
                parameters: parameter, account: account.ncKitAccount
            ) { account, shares, data, error in
                let shareCount = shares?.count ?? 0
                Logger.sharesDataSource.info("Received \(shareCount, privacy: .public) shares")
                defer { continuation.resume(returning: shares ?? []) }
                guard error == .success else {
                    self.presentError("Error fetching shares: \(error.errorDescription)")
                    return
                }
            }
        }
    }

    private static func generateInternalShare(for file: NKFile) -> NKShare {
        let internalShare = NKShare()
        internalShare.shareType = NKShare.ShareType.internalLink.rawValue
        internalShare.url = file.urlBase +  "/index.php/f/" + file.fileId
        internalShare.account = file.account
        internalShare.displaynameOwner = file.ownerDisplayName
        internalShare.displaynameFileOwner = file.ownerDisplayName
        internalShare.path = file.path
        return internalShare
    }

    private func fetchCapabilities() async -> Capabilities? {
        guard let account else {
            self.presentError("Could not fetch capabilities as account is invalid.")
            return nil
        }

        return await withCheckedContinuation { continuation in
            kit.getCapabilities(account: account.ncKitAccount) { account, data, error in
                guard error == .success, let capabilitiesJson = data?.data else {
                    self.presentError("Error getting server caps: \(error.errorDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                Logger.sharesDataSource.info("Successfully retrieved server share capabilities")
                continuation.resume(returning: Capabilities(data: capabilitiesJson))
            }
        }
    }

    private func presentError(_ errorString: String) {
        Logger.sharesDataSource.error("\(errorString, privacy: .public)")
        Task { @MainActor in self.uiDelegate?.showError(errorString) }
    }

    // MARK: - NSTableViewDataSource protocol methods

    @objc func numberOfRows(in tableView: NSTableView) -> Int {
        shares.count
    }

    // MARK: - NSTableViewDelegate protocol methods

    @objc func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let share = shares[row]
        guard let view = tableView.makeView(
            withIdentifier: shareItemViewIdentifier, owner: self
        ) as? ShareTableItemView else {
            Logger.sharesDataSource.error("Acquired item view from table is not a share item view!")
            return nil
        }
        view.share = share
        return view
    }

    @objc func tableViewSelectionDidChange(_ notification: Notification) {
        guard let selectedRow = sharesTableView?.selectedRow, selectedRow >= 0 else {
            Task { @MainActor in uiDelegate?.hideOptions(self) }
            return
        }
        let share = shares[selectedRow]
        Task { @MainActor in uiDelegate?.showOptions(share: share) }
    }
}
