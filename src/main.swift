/*
 * mac-menu
 * A macOS menu application for quick search and selection like dmenu/fzf
 *
 * Author: Sadik Saifi
 * Created: 2025-05-02
 * License: MIT
 */

import Cocoa
import Darwin

/// A custom table row view that provides hover and selection effects
class HoverTableRowView: NSTableRowView {
    /// Draws the selection highlight with rounded corners
    /// - Parameter dirtyRect: The area that needs to be redrawn
    override func drawSelection(in dirtyRect: NSRect) {
        if self.selectionHighlightStyle != .none {
            let selectionRect = NSRect(x: 4, y: 0, width: self.bounds.width - 8, height: self.bounds.height)
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.33).setFill()
            path.fill()
        }
    }
    
    /// Updates the tracking area for mouse hover effects
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        self.removeTrackingArea(self.trackingAreas.first ?? NSTrackingArea())
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil))
    }
    
    /// Handles mouse enter events to show hover effect
    /// - Parameter event: The mouse event
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if !isSelected {
            let hoverRect = NSRect(x: 4, y: 0, width: self.bounds.width - 8, height: self.bounds.height)
            let path = NSBezierPath(roundedRect: hoverRect, xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            path.fill()
        }
        self.needsDisplay = true
    }
    
    /// Handles mouse exit events to remove hover effect
    /// - Parameter event: The mouse event
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        self.needsDisplay = true
    }
}

/// Main application class that implements the menu interface
class MenuApp: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    // MARK: - Properties
    
    /// The main application window
    var window: NSWindow!
    
    /// Table view for displaying and selecting items
    var tableView: NSTableView!
    
    /// Search field for filtering items
    var searchField: NSSearchField!
    
    /// Scroll view containing the table view
    var scrollView: NSScrollView!
    
    /// All available items before filtering
    var allItems: [String] = []
    
    /// Items filtered by search query
    var filteredItems: [String] = []
    
    /// Previously active application before mac-menu was launched
    var previouslyActiveApp: NSRunningApplication?
    
    /// Custom placeholder text for the search field
    var placeholderText: String = "Search..."
    
    /// Fuzzy search result containing the matched string and its score
    private struct FuzzyMatchResult {
        let string: String
        let score: Int
        let positions: [Int]
    }
    
    /// Constants for scoring
    private struct ScoreConfig {
        static let bonusMatch: Int = 16
        static let bonusBoundary: Int = 16
        static let bonusConsecutive: Int = 16
        static let penaltyGapStart: Int = -3
        static let penaltyGapExtension: Int = -1
        static let penaltyNonContiguous: Int = -5
    }
    
    /// Fuzzy search function implementing fzf's algorithm
    /// - Parameters:
    ///   - pattern: The search pattern to match
    ///   - string: The string to search in
    /// - Returns: A tuple containing whether there's a match and the match result
    private func fuzzyMatch(pattern: String, string: String) -> (Bool, FuzzyMatchResult?) {
        let pattern = pattern.lowercased()
        let string = string.lowercased()
        
        // Empty pattern matches everything
        if pattern.isEmpty {
            return (true, FuzzyMatchResult(string: string, score: 0, positions: []))
        }
        
        let patternLength = pattern.count
        let stringLength = string.count
        
        // If pattern is longer than string, no match possible
        if patternLength > stringLength {
            return (false, nil)
        }
        
        // Initialize score matrix
        var scores = Array(repeating: Array(repeating: 0, count: stringLength + 1), count: patternLength + 1)
        var positions = Array(repeating: Array(repeating: [Int](), count: stringLength + 1), count: patternLength + 1)
        
        // Fill score matrix
        for i in 1...patternLength {
            for j in 1...stringLength {
                let patternChar = pattern[pattern.index(pattern.startIndex, offsetBy: i - 1)]
                let stringChar = string[string.index(string.startIndex, offsetBy: j - 1)]
                
                if patternChar == stringChar {
                    var score = ScoreConfig.bonusMatch
                    
                    // Bonus for boundary
                    if j == 1 || string[string.index(string.startIndex, offsetBy: j - 2)] == " " {
                        score += ScoreConfig.bonusBoundary
                    }
                    
                    // Bonus for consecutive matches
                    if i > 1 && j > 1 && pattern[pattern.index(pattern.startIndex, offsetBy: i - 2)] == string[string.index(string.startIndex, offsetBy: j - 2)] {
                        score += ScoreConfig.bonusConsecutive
                    }
                    
                    let prevScore = scores[i - 1][j - 1]
                    let newScore = prevScore + score
                    
                    // Check if we should extend previous match or start new one
                    if newScore > scores[i - 1][j] + ScoreConfig.penaltyGapStart {
                        scores[i][j] = newScore
                        positions[i][j] = positions[i - 1][j - 1] + [j - 1]
                    } else {
                        scores[i][j] = scores[i - 1][j] + ScoreConfig.penaltyGapStart
                        positions[i][j] = positions[i - 1][j]
                    }
                } else {
                    // Penalty for gaps
                    let gapScore = max(
                        scores[i][j - 1] + ScoreConfig.penaltyGapExtension,
                        scores[i - 1][j] + ScoreConfig.penaltyGapStart
                    )
                    scores[i][j] = gapScore
                    positions[i][j] = positions[i][j - 1]
                }
            }
        }
        
        // Check if we found a match
        let finalScore = scores[patternLength][stringLength]
        if finalScore > 0 {
            return (true, FuzzyMatchResult(
                string: string,
                score: finalScore,
                positions: positions[patternLength][stringLength]
            ))
        }
        
        return (false, nil)
    }
    
    // MARK: - Application Lifecycle
    
    /// Sets up the application window and UI components
    /// - Parameter notification: The launch notification
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture the previously active application
        previouslyActiveApp = NSWorkspace.shared.frontmostApplication
        
        // Set custom placeholder text if provided
        placeholderText = getPlaceholderText()
        
        let screenSize = NSScreen.main!.frame
        let width: CGFloat = 720
        let itemHeight: CGFloat = 20
        let maxVisibleItems: CGFloat = 32
        let searchHeight: CGFloat = 50
        let borderRadius: CGFloat = 12
        
        // Calculate fixed height based on maximum visible items
        let height = searchHeight + (itemHeight * maxVisibleItems)

        // Create and configure the main window
        window = NSWindow(
            contentRect: NSRect(x: (screenSize.width - width) / 2,
                                y: (screenSize.height - height) / 2,
                                width: width,
                                height: height),
            styleMask: [.titled, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        // Add mouse event monitor to handle clicks outside the window (only if not in persistent mode)
        if !isPersistentMode() {
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self = self else { return }
                let windowFrame = self.window.frame
                let clickPoint = event.locationInWindow
                
                // Convert click point to screen coordinates
                let screenPoint = self.window.convertPoint(toScreen: clickPoint)
                
                // Check if click is outside window frame
                if !windowFrame.contains(screenPoint) {
                    self.terminateWithFocusRestoration()
                }
            }
        }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.hasShadow = true
        
        // Configure window shadow
        if let windowFrame = window.contentView?.superview {
            windowFrame.wantsLayer = true
            windowFrame.shadow = NSShadow()
            windowFrame.layer?.shadowColor = NSColor.black.cgColor
            windowFrame.layer?.shadowOpacity = 0.4
            windowFrame.layer?.shadowOffset = NSSize(width: 0, height: -2)
            windowFrame.layer?.shadowRadius = 20
        }
        
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.hidesOnDeactivate = false
        
        // Prevent multiple instances from appearing in dock
        NSApp.setActivationPolicy(.accessory)
        
        // Main container with border
        let containerView = NSView(frame: window.contentView!.bounds)
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = borderRadius
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        window.contentView?.addSubview(containerView)
        
        // Background blur effect
        let blurView = NSVisualEffectView(frame: containerView.bounds)
        blurView.autoresizingMask = [.width, .height]
        blurView.blendingMode = .behindWindow
        blurView.material = .hudWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = borderRadius
        
        // Add subtle inner shadow to enhance depth
        blurView.layer?.masksToBounds = false
        let innerShadow = NSShadow()
        innerShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        innerShadow.shadowOffset = NSSize(width: 0, height: -1)
        innerShadow.shadowBlurRadius = 3
        blurView.shadow = innerShadow
        
        // Add subtle gradient overlay for glass effect
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = containerView.bounds
        gradientLayer.colors = [
            NSColor.white.withAlphaComponent(0.15).cgColor,
            NSColor.white.withAlphaComponent(0.08).cgColor
        ]
        gradientLayer.locations = [0.0, 1.0]
        gradientLayer.cornerRadius = borderRadius
        
        // Overlay view for gradient
        let overlayView = NSView(frame: containerView.bounds)
        overlayView.wantsLayer = true
        overlayView.layer?.cornerRadius = borderRadius
        overlayView.layer?.addSublayer(gradientLayer)
        
        containerView.addSubview(blurView)
        containerView.addSubview(overlayView)
        
        // Make overlay view more opaque
        overlayView.alphaValue = 0.5
        
        // Search field - position at top with vertical centering
        let searchFieldHeight: CGFloat = 32
        let verticalPadding: CGFloat = 6  // Reduced padding for tighter layout
        let searchFieldY = height - searchHeight + verticalPadding
        let horizontalPadding: CGFloat = 0
        let textPadding: CGFloat = 2
        
        // Add search icon
        let searchIcon = NSImageView(frame: NSRect(x: horizontalPadding + 12,
                                                  y: searchFieldY + (searchFieldHeight - 16) / 2,  // Center vertically
                                                  width: 24,
                                                  height: 24))
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .light)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?.withSymbolConfiguration(config)
        searchIcon.contentTintColor = NSColor.labelColor.withAlphaComponent(0.6)
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        containerView.addSubview(searchIcon)
        
        // Configure search field
        searchField = NSSearchField(frame: NSRect(x: horizontalPadding + textPadding + 36, 
                                                y: searchFieldY,
                                                width: width - (horizontalPadding + textPadding) * 2 - 36, 
                                                height: searchFieldHeight))
        searchField.wantsLayer = true
        searchField.focusRingType = .none
        searchField.delegate = self
        
        // Create a custom clear appearance
        let clearAppearance = NSAppearance(named: .darkAqua)
        searchField.appearance = clearAppearance
        
        // Configure search field cell
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.font = NSFont.systemFont(ofSize: 20, weight: .regular)
            cell.placeholderString = placeholderText
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
            cell.bezelStyle = .squareBezel
            cell.backgroundColor = NSColor.clear
            cell.drawsBackground = false
            cell.sendsActionOnEndEditing = true
            cell.isScrollable = true
            cell.usesSingleLineMode = true
            cell.textColor = NSColor.labelColor
            
            // Set proper text attributes for padding
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = 6
            style.headIndent = 6
            let attributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: style,
                .font: NSFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
            cell.placeholderAttributedString = NSAttributedString(string: placeholderText, attributes: attributes)
        }
        
        // Enable paste functionality - users can now paste text using Cmd+V
        searchField.allowsEditingTextAttributes = false
        searchField.isEditable = true
        searchField.isSelectable = true
        
        // Remove any border or background from the search field itself
        searchField.layer?.borderWidth = 0
        searchField.layer?.cornerRadius = 0
        searchField.layer?.masksToBounds = true
        searchField.textColor = NSColor.labelColor
        searchField.backgroundColor = NSColor.clear
        searchField.drawsBackground = false
        searchField.isBezeled = false
        searchField.isBordered = false
        
        // Force the field editor to be transparent
        if let fieldEditor = window.fieldEditor(false, for: searchField) as? NSTextView {
            fieldEditor.backgroundColor = NSColor.clear
            fieldEditor.drawsBackground = false
            // Enable paste functionality in the field editor
            fieldEditor.isEditable = true
            fieldEditor.isSelectable = true
        }
        
        // Remove the default search field styling from all subviews
        searchField.subviews.forEach { subview in
            subview.wantsLayer = true
            if let layer = subview.layer {
                layer.backgroundColor = NSColor.clear.cgColor
            }
            if let textField = subview as? NSTextField {
                textField.backgroundColor = NSColor.clear
                textField.drawsBackground = false
                textField.isBezeled = false
                textField.isBordered = false
            }
        }
        
        containerView.addSubview(searchField)
        
        // Separator line
        let separator = NSView(frame: NSRect(x: horizontalPadding, 
                                           y: height - searchHeight, 
                                           width: width - horizontalPadding * 2, 
                                           height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        containerView.addSubview(separator)

        // Configure table view
        let tableHeight = height - searchHeight
        let sideMargin: CGFloat = 2
        scrollView = NSScrollView(frame: NSRect(x: sideMargin, 
                                              y: sideMargin, 
                                              width: width - (sideMargin * 2), 
                                              height: tableHeight - sideMargin))
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.alphaValue = 0
        scrollView.backgroundColor = NSColor.clear
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        tableView = NSTableView(frame: scrollView.bounds)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.backgroundColor = NSColor.clear
        tableView.selectionHighlightStyle = .regular
        tableView.enclosingScrollView?.drawsBackground = false
        tableView.rowHeight = itemHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.action = #selector(handleClick)
        tableView.target = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemColumn"))
        column.width = scrollView.frame.width
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        containerView.addSubview(scrollView)

        window.makeFirstResponder(searchField)
        
        // Ensure the search field is properly configured for paste functionality
        if let fieldEditor = window.fieldEditor(false, for: searchField) as? NSTextView {
            fieldEditor.isEditable = true
            fieldEditor.isSelectable = true
        }
        
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        // Ensure window gets and maintains focus
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        
        // Force focus after a brief delay to ensure window is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window.becomeMain()
        }
        
        // Add focus observer (only if not in persistent mode)
        if !isPersistentMode() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }

        // Window-level key event monitoring
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Handle paste command (Cmd+V)
            if event.modifierFlags.contains(.command) && event.keyCode == 9 { // Cmd+V
                if let pasteboard = NSPasteboard.general.string(forType: .string) {
                    self.searchField.stringValue = pasteboard
                    // Trigger the search field change event
                    self.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: self.searchField))
                    return nil
                }
            }
            
            // Navigation keys
            if event.keyCode == 126 || // Up arrow
               (event.modifierFlags.contains(.control) && event.keyCode == 35) { // Ctrl + P
                self.moveSelection(offset: -1)
                return nil
            }
            
            if event.keyCode == 125 || // Down arrow
               (event.modifierFlags.contains(.control) && event.keyCode == 45) { // Ctrl + N
                self.moveSelection(offset: 1)
                return nil
            }

            // Enter key
            if event.keyCode == 36 {
                self.selectCurrentRow()
                return nil
            }

            // Escape key
            if event.keyCode == 53 {
                let query = self.searchField.stringValue
                if !query.isEmpty {
                    // Clear the search query
                    self.searchField.stringValue = ""
                    self.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: self.searchField))
                } else {
                    // Close the application if no search query
                    self.terminateWithFocusRestoration()
                }
                return nil
            }

            return event
        }

        loadInput()
    }
    
    // MARK: - Input Handling
    
    /// Loads input from stdin and populates the items list
    func loadInput() {
        // Check if stdin is a terminal
        if isatty(FileHandle.standardInput.fileDescriptor) != 0 {
            print("Error: No input provided. Please pipe some input into mac-menu.")
            print("Use 'mac-menu --help' to learn more about how to use the program.")
            NSApp.terminate(nil)
            return
        }
        
        // Try to read available input
        if let input = try? String(data: FileHandle.standardInput.readToEnd() ?? Data(), encoding: .utf8) {
            if input.isEmpty {
                print("Error: No input provided. Please pipe some input into mac-menu.")
                print("Use 'mac-menu --help' to learn more about how to use the program.")
                NSApp.terminate(nil)
                return
            }
            allItems = input.components(separatedBy: .newlines).filter { !$0.isEmpty }
            filteredItems = allItems
            tableView.reloadData()
            selectRow(index: 0)
        } else {
            print("Error: No input provided. Please pipe some input into mac-menu.")
            print("Use 'mac-menu --help' to learn more about how to use the program.")
            NSApp.terminate(nil)
        }
    }
    
    // MARK: - Table View Data Source
    
    /// Returns the number of rows in the table view
    /// - Parameter tableView: The table view requesting the information
    /// - Returns: The number of rows
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredItems.count
    }
    
    /// Provides the view for a table column
    /// - Parameters:
    ///   - tableView: The table view requesting the view
    ///   - tableColumn: The column for which to provide the view
    ///   - row: The row for which to provide the view
    /// - Returns: The view to display in the table cell
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellPadding: CGFloat = 2
        
        // Create container for proper padding and hover state
        let container = NSView(frame: NSRect(x: 0, y: 0, width: tableView.frame.width, height: tableView.rowHeight))
        container.wantsLayer = true
        
        // Create a custom text field with proper vertical centering
        let cell = NSTextField()
        cell.stringValue = filteredItems[row]
        cell.textColor = NSColor.labelColor
        cell.backgroundColor = NSColor.clear
        cell.isBordered = false
        cell.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        cell.lineBreakMode = .byTruncatingTail
        cell.alignment = .left
        cell.isEditable = false
        cell.isSelectable = false
        
        // Configure the cell for proper vertical alignment
        if let cellCell = cell.cell as? NSTextFieldCell {
            cellCell.usesSingleLineMode = true
            cellCell.isScrollable = false
        }
        
        // Calculate the natural height of the text and center it
        let textSize = cell.cell?.cellSize ?? NSSize(width: 0, height: 16)
        let yOffset = (container.frame.height - textSize.height) / 2
        
        // Position the cell with proper padding and vertical centering
        cell.frame = NSRect(x: cellPadding, 
                          y: yOffset,
                          width: container.frame.width - (cellPadding), 
                          height: textSize.height)
        
        container.addSubview(cell)
        return container
    }
    
    /// Provides a custom row view for the table
    /// - Parameters:
    ///   - tableView: The table view requesting the row view
    ///   - row: The row for which to provide the view
    /// - Returns: A custom row view with hover effects
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = HoverTableRowView()
        rowView.wantsLayer = true
        rowView.backgroundColor = NSColor.clear
        return rowView
    }
    
    /// Returns the height for a specific row
    /// - Parameters:
    ///   - tableView: The table view requesting the height
    ///   - row: The row for which to return the height
    /// - Returns: The height of the row
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 24 // Tighter row height
    }
    
    /// Called when a row view is added to the table
    /// - Parameters:
    ///   - tableView: The table view
    ///   - rowView: The row view that was added
    ///   - row: The row index
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.backgroundColor = .clear
    }
    
    // MARK: - Table View Delegate
    
    /// Determines if a row should be selectable
    /// - Parameters:
    ///   - tableView: The table view
    ///   - row: The row to check
    /// - Returns: true if the row should be selectable
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return true
    }
    
    /// Called when the selection changes in the table view
    /// - Parameter notification: The notification object
    func tableViewSelectionDidChange(_ notification: Notification) {
        // Nothing needed unless we want side effects on selection
    }
    
    // MARK: - Search Field Delegate
    
    /// Called when the search field text changes
    /// - Parameter obj: The notification object
    func controlTextDidChange(_ obj: Notification) {
        guard let searchField = obj.object as? NSSearchField else { return }
        let query = searchField.stringValue
        
        if query.isEmpty {
            filteredItems = allItems
        } else {
            // Get matches with scores
            let matches = allItems.compactMap { item -> (String, FuzzyMatchResult)? in
                let (_, result) = fuzzyMatch(pattern: query, string: item)
                return result.map { (item, $0) }
            }
            .sorted { $0.1.score > $1.1.score }
            
            // Extract just the original strings in order of score
            filteredItems = matches.map { $0.0 }
        }
        
        tableView.reloadData()
        if !filteredItems.isEmpty {
            selectRow(index: 0)
        }
    }
    
    /// Called when the search field begins editing
    /// - Parameter obj: The notification object
    func controlTextDidBeginEditing(_ obj: Notification) {
        // Ensure the search field can handle paste events
        if let searchField = obj.object as? NSSearchField {
            searchField.isEditable = true
            searchField.isSelectable = true
        }
    }
    
    /// Called when the search field ends editing
    /// - Parameter obj: The notification object
    func controlTextDidEndEditing(_ obj: Notification) {
        // Handle any cleanup if needed
    }
    
    /// Handles special key commands in the search field
    /// - Parameters:
    ///   - control: The control sending the command
    ///   - textView: The text view handling the input
    ///   - commandSelector: The selector for the command
    /// - Returns: true if the command was handled
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        return false  // Let the default key handling work
    }
    

    
    // MARK: - Selection Handling
    
    /// Moves the selection up or down by the specified offset
    /// - Parameter offset: The number of rows to move (negative for up, positive for down)
    func moveSelection(offset: Int) {
        let current = tableView.selectedRow
        guard filteredItems.count > 0 else { return }

        var next = current + offset
        if next < 0 { next = 0 }
        if next >= filteredItems.count { next = filteredItems.count - 1 }

        selectRow(index: next)
    }
    
    /// Selects a specific row in the table
    /// - Parameter index: The index of the row to select
    func selectRow(index: Int) {
        if filteredItems.isEmpty { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }
    
    /// Handles the selection of the current row
    func selectCurrentRow() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredItems.count else { return }
        print(filteredItems[row])
        fflush(stdout)
        terminateWithFocusRestoration()
    }
    
    /// Handles click events on table rows
    @objc func handleClick() {
        selectCurrentRow()
    }

    // MARK: - Window Focus Handling
    
    /// Handles window focus loss
    @objc func windowDidResignKey(_ notification: Notification) {
        // Regain focus if we're still the active window
        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    /// Restores focus to the previously active application
    func restorePreviousAppFocus() {
        if let previousApp = previouslyActiveApp, previousApp.isActive == false {
            previousApp.activate()
        }
    }
    
    /// Terminates the application and restores focus to the previously active app
    func terminateWithFocusRestoration() {
        // restorePreviousAppFocus()
        NSApp.terminate(nil)
    }
}

private let helpFlags: Set<String>     = ["-h", "--help", "help"]
private let versionFlags: Set<String>  = ["-v", "--version", "version"]
private let persistentFlags: Set<String> = ["--persistent", "persistent"]
private let placeholderFlags: Set<String> = ["-p", "--placeholder"]

private func handleEarlyFlags() {
    let args = Set(CommandLine.arguments.dropFirst())

    if !helpFlags.isDisjoint(with: args) {
        print("""
        mac-menu – does wonderful things with piped input.

        USAGE:
          mac-menu [options]

        OPTIONS:
          -h, --help,   help      Show this help and quit
          -v, --version,version   Show version and quit
          --persistent            Disable close-on-blur behavior (window stays open when clicking outside)
          -p, --placeholder <text>  Set custom placeholder text for the search field
        """)
        exit(EXIT_SUCCESS)
    }

    if !versionFlags.isDisjoint(with: args) {
        let version = "0.0.1"
        print("mac-menu \(version)")
        exit(EXIT_SUCCESS)
    }
}

private func isPersistentMode() -> Bool {
    let args = Set(CommandLine.arguments.dropFirst())
    return !persistentFlags.isDisjoint(with: args)
}

private func getPlaceholderText() -> String {
    let args = CommandLine.arguments
    
    // Check for placeholder flag at any position
    for i in 0..<args.count - 1 {
        if args[i] == "-p" || args[i] == "--placeholder" {
            return args[i + 1]
        }
    }
    
    return "Search..." // Default placeholder text
}

handleEarlyFlags()

// Start app
let app = NSApplication.shared
let delegate = MenuApp()
app.delegate = delegate
app.run()
