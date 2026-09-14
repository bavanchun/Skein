//
//  LaunchAnimationController.swift
//  Skein
//

import AVFoundation
import Combine
import Cocoa

/// A short, nonactivating introduction. App setup never waits for playback.
@MainActor
final class LaunchAnimationController {
    private let bundle: Bundle
    private var hasPresented = false
    private var panel: NSPanel?
    private var player: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    private var dismissalTask: Task<Void, Never>?
    private var isDismissing = false
    private var reduceMotion = false
    private var menuBarDestination: (() -> NSRect?)?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func showIfNeeded(
        isLoginLaunch: Bool,
        isPreview: Bool,
        reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        allowReplay: Bool = false,
        menuBarDestination: (() -> NSRect?)? = nil
    ) {
        guard !hasPresented || allowReplay, panel == nil, !isLoginLaunch, !isPreview else {
            return
        }
        hasPresented = true
        isDismissing = false
        self.reduceMotion = reduceMotion
        self.menuBarDestination = menuBarDestination

        let posterURL = bundle.url(forResource: "skein-launch-poster", withExtension: "png")
        let poster = posterURL.flatMap { NSImage(contentsOf: $0) }
        let movieURL = bundle.url(forResource: "skein-launch", withExtension: "mp4")
        guard poster != nil || (!reduceMotion && movieURL != nil) else {
            return
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
        content.wantsLayer = true
        content.layer?.cornerRadius = 24
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        let still = NSImageView(frame: content.bounds)
        still.image = poster
        still.imageScaling = .scaleProportionallyUpOrDown
        still.autoresizingMask = [.width, .height]
        content.addSubview(still)
        content.setAccessibilityElement(true)
        content.setAccessibilityLabel("Skein")
        content.setAccessibilityRole(.image)

        let panel = NSPanel(
            contentRect: content.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("SkeinLaunchAnimation")
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.center()
        self.panel = panel

        guard !reduceMotion, let movieURL else {
            panel.orderFrontRegardless()
            scheduleDismissal(after: 0.55)
            return
        }

        let item = AVPlayerItem(url: movieURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        self.player = player

        let movieLayer = AVPlayerLayer(player: player)
        movieLayer.frame = content.bounds
        movieLayer.videoGravity = .resizeAspect
        // AppKit can composite the poster subview above a manually added layer.
        // Host video in its own view and keep the poster only for the still path.
        still.removeFromSuperview()
        let movieView = NSView(frame: content.bounds)
        movieView.layer = movieLayer
        movieView.wantsLayer = true
        movieView.autoresizingMask = [.width, .height]
        content.addSubview(movieView)

        // Keep the panel hidden until the decoder has a frame to prevent a black flash.
        movieLayer.publisher(for: \.isReadyForDisplay)
            .filter { $0 }
            .prefix(1)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !isDismissing else {
                    return
                }
                self.panel?.orderFrontRegardless()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.dismiss(towardMenuBar: true)
            }
            .store(in: &cancellables)

        item.publisher(for: \.status)
            .filter { $0 == .failed }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.dismiss()
            }
            .store(in: &cancellables)

        // A failed or stalled decoder must never leave a floating window behind.
        scheduleDismissal(after: 3.5)
        player.play()
    }

    func dismiss(towardMenuBar: Bool = false) {
        guard let panel, !isDismissing else {
            return
        }
        isDismissing = true
        dismissalTask?.cancel()
        dismissalTask = nil
        cancellables.removeAll()
        player?.pause()

        guard panel.isVisible, !reduceMotion else {
            finishDismissal()
            return
        }
        if towardMenuBar, let destination = menuBarDestination?(), handOff(to: destination) {
            return
        }
        fadeOut()
    }

    /// Only completed playback points to a visible control on the current display.
    /// Settings, decoder failure and reduced motion use the ordinary dismissal.
    private func handOff(to destination: NSRect) -> Bool {
        guard
            let panel, let content = panel.contentView,
            let screen = panel.screen,
            destination.width > 1, destination.width < 128,
            destination.height > 0, destination.height < 64,
            screen.frame.contains(destination),
            let url = bundle.url(forResource: "skein-launch-mark", withExtension: "png"),
            let mark = NSImage(contentsOf: url)
        else {
            return false
        }

        let container = NSView(frame: content.bounds)
        panel.contentView = container
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        let image = NSImageView(frame: container.bounds)
        image.image = mark
        image.imageScaling = .scaleProportionallyUpOrDown
        image.autoresizingMask = [.width, .height]
        container.addSubview(image)
        panel.hasShadow = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            content.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, let panel = self.panel else {
                    return
                }
                // The mark sits 0.6 units above center in the 7.4-unit render canvas.
                let size: CGFloat = 44
                let target = NSRect(
                    x: destination.midX - size / 2,
                    y: destination.midY - size / 2 - size * 0.6 / 7.4,
                    width: size,
                    height: size
                )
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.42
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(target, display: true)
                } completionHandler: { [weak self] in
                    Task { @MainActor in
                        self?.fadeOut()
                    }
                }
            }
        }
        return true
    }

    private func fadeOut() {
        guard let panel else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.finishDismissal()
            }
        }
    }

    private func scheduleDismissal(after seconds: Double) {
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            self?.dismiss()
        }
    }

    private func finishDismissal() {
        player?.replaceCurrentItem(with: nil)
        player = nil
        menuBarDestination = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}
