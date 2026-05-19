import UIKit
import Darwin
import ObjectiveC
import OSLog

private let kbLog = Logger(subsystem: "com.typeforme.keyboard", category: "ui")

final class KeyboardViewController: UIInputViewController {
    private enum CorrectionModePreset: String, CaseIterable {
        case clean
        case polish
        case polishPlus = "polish_plus"
        case structurePlus = "structure_plus"
        case formalPlus = "formal_plus"

        var title: String {
            switch self {
            case .clean: return "Clean"
            case .polish: return "Polish"
            case .polishPlus: return "Polish+"
            case .structurePlus: return "Structure+"
            case .formalPlus: return "Formal+"
            }
        }
    }

    private enum CapsuleStyle {
        case chrome
        case key
        case utility
    }

    private enum TextRewriteTarget {
        case selection(text: String, contextBefore: String, contextAfter: String)
        case context(before: String, after: String)
        case cachedResult(String)
        case pasteboard(String)

        var text: String {
            switch self {
            case .selection(let text, _, _), .cachedResult(let text), .pasteboard(let text):
                return text
            case .context(let before, let after):
                return before + after
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let localClient = KeyboardLocalClient()
    private let inputModeKey = "keyboard.inputMode"
    private let lastInsertedTextKey = "keyboard.lastInsertedText"
    private let lastInsertedCommandIDKey = "keyboard.lastInsertedCommandID"
    private let hostWakePasteboardName = UIPasteboard.Name("com.typeforme.keyboard.wake")
    private let keyboardDefaultsPasteboardName = UIPasteboard.Name("com.typeforme.keyboard.defaults")

    private var correctionMode: CorrectionModePreset = .polish
    private var hasUserSelectedCorrectionMode = false
    private var inputMode: VoiceInputMode = .hold
    private var heightConstraint: NSLayoutConstraint?
    private var statusTimer: Timer?
    private var statusTimerInterval: TimeInterval = 0
    private var lastStatusSignature = ""
    private var bridgeStatus: KeyboardBridgeStatus?
    private var lastBridgeContactAt: TimeInterval = 0
    private var openingHostUntil: TimeInterval = 0
    private var appliedKeyboardInterfaceStyle: UIUserInterfaceStyle?
    private var lastCorrectionModeButtonSignature = ""
    private var hasPresentedInitialFrame = false
    private var isVoicePressActive = false
    private var voicePressBeganAt: TimeInterval = 0
    private var isStartRequestInFlight = false
    private var shouldStopWhenStartCompletes = false
    private var shouldCancelWhenStartCompletes = false
    private var tapRecordingActive = false
    private var isCommandPressActive = false
    private var activeRecordingTextTarget: TextRewriteTarget?
    private var recentSelectionTarget: TextRewriteTarget?
    private var recentSelectionCapturedAt: TimeInterval = 0
    private var styleRewriteCommandID: String?
    private var scheduledHostOpenTask: Task<Void, Never>?
    private var scheduledStopTask: Task<Void, Never>?
    private var deleteRepeatTask: Task<Void, Never>?
    private var deferredStartupWorkItem: DispatchWorkItem?
    private var keyboardDarwinObservers: [KeyboardDarwinNotificationObserver] = []
    private let minimumHoldRecordingDuration: TimeInterval = 0.55
    private let minimumIntentReleaseDuration: TimeInterval = 0.28
    private let selectionSnapshotTTL: TimeInterval = 1.25
    private static let dictationContextLimit = 600
    private static let textRewriteContextExpansionLimit = 2_000
    private static let textRewriteContextExpansionMaxSteps = 40
    private let deleteRepeatInitialDelay: UInt64 = 450_000_000
    private let deleteRepeatInterval: UInt64 = 70_000_000

    private let rootStack = UIStackView()
    private let topRow = UIView()
    private let statusGroup = UIStackView()
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    private let settingsButton = UIButton(type: .system)
    private let correctionModePanel = UIStackView()
    private var correctionModeButtons: [(preset: CorrectionModePreset, button: UIButton)] = []

    /// Circular orb (`voiceButton`) sits centered in `orbContainer`. Pulse
    /// rings are rendered as direct sublayers kept behind the orb in z-order.
    private let orbContainer = UIView()
    private let voiceButton = VoiceOrbButton(type: .custom)
    private let voiceGradient = CAGradientLayer()
    private let voiceHighlight = CAGradientLayer()
    private var pulseRings: [CAShapeLayer] = []
    private let voiceIconView = UIImageView()
    private let voicePrint = VoicePrintView()
    private let voiceSpinner = UIActivityIndicatorView(style: .large)
    private let voiceTitleLabel = UILabel()
    private let inputModeSwitch = VoiceInputModeSwitch()
    private static let orbDiameter: CGFloat = 132
    private static let rootVerticalInset: CGFloat = 6
    private static let stackSpacing: CGFloat = 6
    private static let topRowHeight: CGFloat = 30
    private static let orbContainerHeight: CGFloat = 146
    private static let utilityRowHeight: CGFloat = 42
    private static var contentHeight: CGFloat {
        rootVerticalInset * 2 + stackSpacing * 2 + topRowHeight + orbContainerHeight + utilityRowHeight
    }
    private static let topChromeCoverHeight: CGFloat = 0

    private let utilityRow = UIStackView()
    private let pasteButton = UIButton(type: .system)
    private let commandButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        configureSystemKeyboardAffordances()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSystemKeyboardAffordances()
    }

    override func loadView() {
        let rootView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        rootView.allowsSelfSizing = false
        rootView.isOpaque = false
        rootView.backgroundColor = .clear
        rootView.clipsToBounds = false
        rootView.layer.masksToBounds = false
        rootView.layer.backgroundColor = UIColor.clear.cgColor
        inputView = rootView
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureSystemKeyboardAffordances()
        loadState()
        configureRoot()
        configureTopRow()
        configureVoiceButton()
        configureUtilityRow()
        configureKeyboardDarwinBridge()
        applyKeyboardInterfaceStyle(force: true)
        updateUI(animated: false)
        // Keyboard extensions receive the active input scene's appearance as
        // traits. Re-apply concrete colors whenever those traits move; layer
        // colors don't update automatically like UIColor-backed views do.
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardViewController, _) in
                self.refreshDynamicAppearance()
            }
        }
        kbLog.notice("viewDidLoad complete; voiceButton enabled=\(self.voiceButton.isEnabled, privacy: .public), fullAccess=\(self.hasFullAccess, privacy: .public)")
    }

    /// Re-applies layer-level (CGColor) properties that don't follow trait
    /// updates automatically. UIColor-backed properties (label.textColor,
    /// view.backgroundColor with dynamic UIColor) repaint on their own.
    private func refreshDynamicAppearance() {
        applyKeyboardInterfaceStyle()
        let traits = keyboardTraitCollection
        refreshKeyboardBackground()
        voiceButton.layer.shadowColor = UIColor.systemBlue.resolvedColor(with: traits).cgColor
        voiceButton.layer.shadowOpacity = isKeyboardDark ? 0.5 : 0.42
        voiceButton.layer.borderColor = UIColor.white
            .withAlphaComponent(isKeyboardDark ? 0.28 : 0.22)
            .cgColor
        // Pulse rings tint to the same system color family as the orb.
        for ring in pulseRings {
            ring.strokeColor = pulseRingColor.resolvedColor(with: traits).cgColor
        }
        updateUI(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureSystemKeyboardAffordances()
        heightConstraint?.constant = Self.contentHeight + Self.topChromeCoverHeight
        resetCorrectionModeToDefault()
        prepareInitialLayoutForDisplay()
        // The current input scene's style isn't always settled by
        // `viewDidLoad`; pick up whatever's current right before display.
        refreshDynamicAppearance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleDeferredStartupProbe()
    }

    deinit {
        deferredStartupWorkItem?.cancel()
        scheduledHostOpenTask?.cancel()
        keyboardDarwinObservers.forEach { $0.stopObserving() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDeleteRepeat()
        deferredStartupWorkItem?.cancel()
        deferredStartupWorkItem = nil
        cancelScheduledHostOpen()
        stopStatusPolling()
        voicePrint.isActive = false
        stopPulseRings()
    }

    private func loadState() {
        correctionMode = defaultCorrectionModeFromHost() ?? .polish
        defaults.removeObject(forKey: "keyboard.correctionMode")
        if let raw = defaults.string(forKey: inputModeKey),
           let saved = VoiceInputMode(rawValue: raw) {
            inputMode = saved
        }
        defaults.removeObject(forKey: "keyboard.pendingAutoStartUntil")
    }

    private func resetCorrectionModeToDefault() {
        hasUserSelectedCorrectionMode = false
        correctionMode = defaultCorrectionModeFromHost() ?? .polish
        lastCorrectionModeButtonSignature = ""
    }

    private func defaultCorrectionModeFromHost() -> CorrectionModePreset? {
        guard hasFullAccess,
              let pasteboard = UIPasteboard(name: keyboardDefaultsPasteboardName, create: false),
              let text = pasteboard.string,
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = payload["correction_mode"] as? String
        else { return nil }
        return CorrectionModePreset(rawValue: raw)
    }

    private func configureRoot() {
        refreshKeyboardBackground()

        rootStack.axis = .vertical
        rootStack.spacing = Self.stackSpacing
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        heightConstraint = view.heightAnchor.constraint(equalToConstant: Self.contentHeight + Self.topChromeCoverHeight)
        heightConstraint?.priority = .required
        heightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.rootVerticalInset + Self.topChromeCoverHeight),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.rootVerticalInset),
        ])
    }

    private func refreshKeyboardBackground() {
        // Keep the extension's own root transparent. UIInputView with
        // `.keyboard` style supplies the same system keyboard material that
        // iOS uses for the automatic bottom globe/safe-area region.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.backgroundColor = UIColor.clear.cgColor
    }

    private func prepareInitialLayoutForDisplay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.rootStack.layoutIfNeeded()
            self.topRow.layoutIfNeeded()
            self.orbContainer.layoutIfNeeded()
            self.correctionModePanel.layoutIfNeeded()
            self.inputModeSwitch.layoutIfNeeded()
            self.utilityRow.layoutIfNeeded()
        }
        CATransaction.commit()
    }

    @discardableResult
    private func applyKeyboardInterfaceStyle(force: Bool = false) -> Bool {
        let style = keyboardInterfaceStyle
        guard force || appliedKeyboardInterfaceStyle != style else { return false }
        appliedKeyboardInterfaceStyle = style
        lastCorrectionModeButtonSignature = ""
        let views: [UIView] = [
            rootStack,
            topRow,
            statusGroup,
            statusLabel,
            settingsButton,
            correctionModePanel,
            orbContainer,
            voiceButton,
            voiceIconView,
            voicePrint,
            voiceTitleLabel,
            inputModeSwitch,
            utilityRow,
            pasteButton,
            spaceButton,
            deleteButton,
            returnButton,
        ]
        views.forEach { $0.overrideUserInterfaceStyle = style }
        correctionModeButtons.forEach {
            $0.button.overrideUserInterfaceStyle = style
            $0.button.setNeedsUpdateConfiguration()
        }
        [settingsButton, pasteButton, spaceButton, deleteButton, returnButton].forEach {
            $0.setNeedsUpdateConfiguration()
        }
        refreshCapsuleButtonConfigurations()
        inputModeSwitch.refreshAppearance(style: style)
        return true
    }

    private var keyboardTraitCollection: UITraitCollection {
        UITraitCollection(userInterfaceStyle: keyboardInterfaceStyle)
    }

    private var keyboardInterfaceStyle: UIUserInterfaceStyle {
        let controllerStyle = traitCollection.userInterfaceStyle
        if controllerStyle != .unspecified { return controllerStyle }
        let windowStyle = view.window?.windowScene?.traitCollection.userInterfaceStyle ?? .unspecified
        if windowStyle != .unspecified { return windowStyle }
        let screenStyle = UIScreen.main.traitCollection.userInterfaceStyle
        return screenStyle == .dark ? .dark : .light
    }

    private var isKeyboardDark: Bool {
        keyboardInterfaceStyle == .dark
    }

    private func configureSystemKeyboardAffordances() {
        hasDictationKey = true
    }

    private func configureKeyboardDarwinBridge() {
        keyboardDarwinObservers.forEach { $0.stopObserving() }
        keyboardDarwinObservers = [
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.sessionStarted) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.currentBridgeStatus?.state != .recording,
                       self.currentBridgeStatus?.state != .sending {
                        self.applyBridgeStatus(KeyboardBridgeStatus(state: .standby, message: "Ready"))
                    } else {
                        self.openingHostUntil = 0
                        self.lastBridgeContactAt = Date().timeIntervalSince1970
                        self.updateUI()
                    }
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.sessionEnded) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cancelScheduledHostOpen()
                    self.openingHostUntil = 0
                    self.isStartRequestInFlight = false
                    self.tapRecordingActive = false
                    self.bridgeStatus = KeyboardBridgeStatus(state: .idle, message: self.inputMode.idleTitle)
                    self.lastBridgeContactAt = 0
                    self.updateUI()
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.dictationStarted) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let status = KeyboardBridgeStatus(state: .recording, message: "Recording")
                    self.cancelScheduledHostOpen()
                    self.applyBridgeStatus(status)
                    self.finishStartRequestIfNeeded(status: status)
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.dictationStopped) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let wasStarting = self.isStartRequestInFlight
                    self.finishStoppedNotification()
                    if wasStarting, !self.isOpeningHostApp {
                        self.openHostForDictation()
                        return
                    }
                    if self.currentBridgeStatus?.state != .result,
                       self.currentBridgeStatus?.state != .sending {
                        self.bridgeStatus = KeyboardBridgeStatus(state: .standby, message: "Ready")
                        self.updateUI()
                    }
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.transcriptionReady) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshBridgeStatus()
                }
            },
        ]
    }

    private func configureTopRow() {
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.heightAnchor.constraint(equalToConstant: Self.topRowHeight).isActive = true

        // Inline status: just a colored dot and a label. No borders, no
        // background fill - keep the chrome quiet so the orb is the only
        // thing the eye lands on.
        statusGroup.axis = .horizontal
        statusGroup.spacing = 6
        statusGroup.alignment = .center
        statusGroup.translatesAutoresizingMaskIntoConstraints = false

        statusDot.backgroundColor = .systemGray3
        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .secondaryLabel
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.numberOfLines = 1
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        voiceTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        voiceTitleLabel.textColor = .label
        voiceTitleLabel.textAlignment = .center
        voiceTitleLabel.adjustsFontSizeToFitWidth = true
        voiceTitleLabel.minimumScaleFactor = 0.72
        voiceTitleLabel.numberOfLines = 1
        voiceTitleLabel.lineBreakMode = .byTruncatingTail
        voiceTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        voiceTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        voiceTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(settingsButton, image: "gearshape.fill", accessibilityLabel: "Open Typeforme")
        settingsButton.addTarget(self, action: #selector(openHostFromSettingsButton), for: .touchUpInside)
        attachPressAnimation(settingsButton)

        statusGroup.addArrangedSubview(statusDot)
        statusGroup.addArrangedSubview(statusLabel)
        topRow.addSubview(statusGroup)
        topRow.addSubview(voiceTitleLabel)
        topRow.addSubview(settingsButton)
        rootStack.addArrangedSubview(topRow)

        NSLayoutConstraint.activate([
            statusGroup.leadingAnchor.constraint(equalTo: topRow.leadingAnchor, constant: 6),
            statusGroup.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            statusGroup.trailingAnchor.constraint(lessThanOrEqualTo: voiceTitleLabel.leadingAnchor, constant: -8),

            voiceTitleLabel.centerXAnchor.constraint(equalTo: topRow.centerXAnchor),
            voiceTitleLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            voiceTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: topRow.leadingAnchor, constant: 88),
            voiceTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -8),

            settingsButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor, constant: -4),
            settingsButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
        ])
    }

    private func configureIconButton(_ button: UIButton, image: String, accessibilityLabel: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: image)
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7)
        button.configuration = configuration
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityTraits = .button
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.topRowHeight).isActive = true
    }

    private func configureVoiceButton() {
        orbContainer.translatesAutoresizingMaskIntoConstraints = false
        orbContainer.isUserInteractionEnabled = true
        rootStack.addArrangedSubview(orbContainer)

        // Pulse rings: three concentric circles that bloom outward during
        // recording. Added FIRST so they sit below the orb in z-order.
        for _ in 0..<3 {
            let ring = CAShapeLayer()
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = UIColor.systemRed.withAlphaComponent(0.55).cgColor
            ring.lineWidth = 1.5
            ring.opacity = 0
            orbContainer.layer.addSublayer(ring)
            pulseRings.append(ring)
        }

        let diameter = Self.orbDiameter
        voiceButton.layer.cornerRadius = diameter / 2
        voiceButton.layer.cornerCurve = .continuous
        voiceButton.layer.shadowColor = UIColor.systemBlue.cgColor
        voiceButton.layer.shadowOpacity = isKeyboardDark ? 0.5 : 0.42
        voiceButton.layer.shadowRadius = 18
        voiceButton.layer.shadowOffset = CGSize(width: 0, height: 9)
        voiceButton.layer.borderWidth = 0.75
        voiceButton.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        voiceButton.translatesAutoresizingMaskIntoConstraints = false
        voiceButton.accessibilityLabel = "Dictate"
        voiceButton.accessibilityTraits = .button
        voiceButton.isExclusiveTouch = true
        voiceButton.addTarget(self, action: #selector(voicePressDown), for: [.touchDown, .touchDragEnter])
        voiceButton.addTarget(self, action: #selector(voicePressUp), for: .touchUpInside)
        voiceButton.addTarget(self, action: #selector(voicePressCancelled), for: [.touchUpOutside, .touchCancel, .touchDragExit])

        // Linear top-light → bottom-deep gradient. With a circular mask this
        // reads as a sphere; the inner highlight below adds the specular spot.
        voiceGradient.startPoint = CGPoint(x: 0.5, y: 0)
        voiceGradient.endPoint = CGPoint(x: 0.5, y: 1)
        voiceGradient.cornerRadius = diameter / 2
        voiceGradient.cornerCurve = .continuous
        voiceGradient.masksToBounds = true
        voiceButton.layer.insertSublayer(voiceGradient, at: 0)

        // Specular highlight as a radial gradient from white (center, 0.32
        // alpha) to fully transparent (edge). `CAGradientLayer` with
        // `.radial` type renders as a real soft blob on iOS — unlike a plain
        // CALayer with `compositingFilter = "screenBlendMode"`, which is a
        // macOS-only filter that on iOS just shows a hard-edged white patch.
        voiceHighlight.type = .radial
        voiceHighlight.colors = [
            UIColor.white.withAlphaComponent(0.32).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
        voiceHighlight.locations = [0, 1]
        voiceHighlight.startPoint = CGPoint(x: 0.5, y: 0.5)
        voiceHighlight.endPoint = CGPoint(x: 1, y: 1)
        voiceButton.layer.addSublayer(voiceHighlight)

        voicePrint.translatesAutoresizingMaskIntoConstraints = false
        voicePrint.isUserInteractionEnabled = false
        voicePrint.tint = .white
        voicePrint.alpha = 0
        voiceButton.addSubview(voicePrint)

        voiceIconView.contentMode = .scaleAspectFit
        voiceIconView.tintColor = .white
        voiceIconView.translatesAutoresizingMaskIntoConstraints = false
        voiceIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 52, weight: .medium)
        voiceIconView.image = UIImage(systemName: "mic.fill")
        voiceButton.addSubview(voiceIconView)

        voiceSpinner.color = .white
        voiceSpinner.hidesWhenStopped = true
        voiceSpinner.translatesAutoresizingMaskIntoConstraints = false
        voiceButton.addSubview(voiceSpinner)

        configureCorrectionModePanel()
        configureInputModeSwitch()
        inputModeSwitch.onSelection = { [weak self] rawValue in
            self?.selectInputMode(rawValue)
        }
        orbContainer.addSubview(correctionModePanel)
        orbContainer.addSubview(voiceButton)
        orbContainer.addSubview(inputModeSwitch)

        NSLayoutConstraint.activate([
            orbContainer.heightAnchor.constraint(equalToConstant: Self.orbContainerHeight),

            voiceButton.widthAnchor.constraint(equalToConstant: diameter),
            voiceButton.heightAnchor.constraint(equalToConstant: diameter),
            voiceButton.centerXAnchor.constraint(equalTo: orbContainer.centerXAnchor),
            voiceButton.centerYAnchor.constraint(equalTo: orbContainer.centerYAnchor),
            voiceButton.topAnchor.constraint(greaterThanOrEqualTo: orbContainer.topAnchor, constant: 2),
            voiceButton.bottomAnchor.constraint(lessThanOrEqualTo: orbContainer.bottomAnchor, constant: -2),

            voicePrint.leadingAnchor.constraint(equalTo: voiceButton.leadingAnchor, constant: 26),
            voicePrint.trailingAnchor.constraint(equalTo: voiceButton.trailingAnchor, constant: -26),
            voicePrint.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),
            voicePrint.heightAnchor.constraint(equalToConstant: 50),

            voiceIconView.centerXAnchor.constraint(equalTo: voiceButton.centerXAnchor),
            voiceIconView.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),
            voiceIconView.widthAnchor.constraint(equalToConstant: 56),
            voiceIconView.heightAnchor.constraint(equalToConstant: 56),

            voiceSpinner.centerXAnchor.constraint(equalTo: voiceButton.centerXAnchor),
            voiceSpinner.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),

            correctionModePanel.leadingAnchor.constraint(equalTo: orbContainer.leadingAnchor, constant: 10),
            correctionModePanel.trailingAnchor.constraint(lessThanOrEqualTo: voiceButton.leadingAnchor, constant: -8),
            correctionModePanel.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),
            correctionModePanel.widthAnchor.constraint(equalToConstant: 92),
            correctionModePanel.heightAnchor.constraint(equalToConstant: 132),

            inputModeSwitch.leadingAnchor.constraint(greaterThanOrEqualTo: voiceButton.trailingAnchor, constant: 8),
            inputModeSwitch.centerYAnchor.constraint(equalTo: voiceButton.centerYAnchor),
            inputModeSwitch.trailingAnchor.constraint(equalTo: orbContainer.trailingAnchor, constant: -14),
            inputModeSwitch.widthAnchor.constraint(equalToConstant: 68),
            inputModeSwitch.heightAnchor.constraint(equalToConstant: 82),
        ])
    }

    private func configureInputModeSwitch() {
        inputModeSwitch.translatesAutoresizingMaskIntoConstraints = false
        if inputModeSwitch.mode != inputMode.rawValue {
            inputModeSwitch.mode = inputMode.rawValue
        }
        inputModeSwitch.accessibilityLabel = "\(inputMode.title) to Speak"
    }

    private func configureCorrectionModePanel() {
        correctionModePanel.axis = .vertical
        correctionModePanel.spacing = 4
        correctionModePanel.alignment = .fill
        correctionModePanel.distribution = .fillEqually
        correctionModePanel.translatesAutoresizingMaskIntoConstraints = false
        correctionModeButtons.removeAll()

        for preset in CorrectionModePreset.allCases {
            let button = UIButton(type: .system)
            configureCorrectionModeButton(button, preset: preset)
            button.addTarget(self, action: #selector(selectCorrectionModeButton(_:)), for: .touchUpInside)
            attachPressAnimation(button)
            correctionModeButtons.append((preset, button))
            correctionModePanel.addArrangedSubview(button)
        }
        updateCorrectionModeButtons()
    }

    private func configureCorrectionModeButton(_ button: UIButton, preset: CorrectionModePreset) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = preset.title
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 11, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.accessibilityLabel = preset.title
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.72
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        voiceGradient.frame = voiceButton.bounds

        // Position the specular ellipse upper-left, matching the host app's
        // proportions (ellipse center at 0.34, 0.28 of orb diameter). Width
        // 0.55x diameter, height 0.32x → soft horizontal sheen.
        let diameter = Self.orbDiameter
        let highlightWidth = diameter * 0.55
        let highlightHeight = diameter * 0.32
        voiceHighlight.frame = CGRect(
            x: diameter * 0.34 - highlightWidth / 2,
            y: diameter * 0.28 - highlightHeight / 2,
            width: highlightWidth,
            height: highlightHeight
        )

        // Pulse rings: same diameter as the orb, centered on the orb's center
        // within `orbContainer`. They scale outward up to 1.7x during recording.
        let center = voiceButton.center
        for ring in pulseRings {
            ring.frame = CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            ring.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))).cgPath
        }
        CATransaction.commit()
    }

    private func configureUtilityRow() {
        utilityRow.axis = .horizontal
        utilityRow.spacing = 6
        utilityRow.alignment = .fill
        utilityRow.distribution = .fill
        utilityRow.heightAnchor.constraint(equalToConstant: Self.utilityRowHeight).isActive = true

        configureCapsuleButton(pasteButton, title: "", image: "doc.on.clipboard", style: .utility)
        pasteButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        pasteButton.addTarget(self, action: #selector(pasteResult), for: .touchUpInside)
        attachPressAnimation(pasteButton)

        configureCapsuleButton(commandButton, title: "", image: "wand.and.stars", style: .utility)
        commandButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        commandButton.accessibilityLabel = "Command selected text"
        commandButton.addTarget(self, action: #selector(commandPressDown), for: [.touchDown, .touchDragEnter])
        commandButton.addTarget(self, action: #selector(commandPressUp), for: .touchUpInside)
        commandButton.addTarget(self, action: #selector(commandPressCancelled), for: [.touchUpOutside, .touchCancel, .touchDragExit])

        configureCapsuleButton(spaceButton, title: "space", image: nil, style: .key)
        spaceButton.addTarget(self, action: #selector(insertSpace), for: .touchDown)
        attachPressAnimation(spaceButton)

        configureCapsuleButton(deleteButton, title: "", image: "delete.left", style: .utility)
        deleteButton.widthAnchor.constraint(equalToConstant: 54).isActive = true
        deleteButton.addTarget(self, action: #selector(deletePressDown), for: [.touchDown, .touchDragEnter])
        deleteButton.addTarget(self, action: #selector(deletePressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        attachPressAnimation(deleteButton)

        configureCapsuleButton(returnButton, title: "return", image: nil, style: .utility)
        returnButton.widthAnchor.constraint(equalToConstant: 78).isActive = true
        returnButton.addTarget(self, action: #selector(insertReturn), for: .touchDown)
        attachPressAnimation(returnButton)

        utilityRow.addArrangedSubview(pasteButton)
        utilityRow.addArrangedSubview(commandButton)
        utilityRow.addArrangedSubview(spaceButton)
        utilityRow.addArrangedSubview(deleteButton)
        utilityRow.addArrangedSubview(returnButton)
        rootStack.addArrangedSubview(utilityRow)
    }

    private func configureCapsuleButton(_ button: UIButton, title: String, image: String?, style: CapsuleStyle) {
        button.configuration = capsuleButtonConfiguration(title: title, image: image, style: style)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.72
    }

    private func refreshCapsuleButtonConfigurations() {
        pasteButton.configuration = capsuleButtonConfiguration(title: "", image: "doc.on.clipboard", style: .utility)
        commandButton.configuration = capsuleButtonConfiguration(title: "", image: "wand.and.stars", style: .utility)
        spaceButton.configuration = capsuleButtonConfiguration(title: "space", image: nil, style: .key)
        deleteButton.configuration = capsuleButtonConfiguration(title: "", image: "delete.left", style: .utility)
        returnButton.configuration = capsuleButtonConfiguration(title: "return", image: nil, style: .utility)
    }

    private func capsuleButtonConfiguration(title: String, image: String?, style: CapsuleStyle) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = image.map { UIImage(systemName: $0) } ?? nil
        configuration.imagePlacement = .leading
        configuration.imagePadding = title.isEmpty ? 0 : 5
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        configuration.titleAlignment = .center

        let font: UIFont = title.count > 5 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 15, weight: .semibold)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }

        switch style {
        case .chrome:
            configuration.baseBackgroundColor = UIColor.secondarySystemGroupedBackground
                .withAlphaComponent(isKeyboardDark ? 0.32 : 0.72)
        case .key:
            configuration.baseBackgroundColor = UIColor.systemBackground
                .withAlphaComponent(isKeyboardDark ? 0.34 : 0.78)
        case .utility:
            configuration.baseBackgroundColor = UIColor.secondarySystemBackground
                .withAlphaComponent(isKeyboardDark ? 0.30 : 0.72)
        }
        configuration.baseForegroundColor = .label

        return configuration
    }

    private func updateUI(animated: Bool = true) {
        updateCorrectionModeButtons()
        configureInputModeSwitch()

        let state = currentBridgeStatus?.state
        let isRecordingState = state == .recording
        let isSendingState = state == .sending

        let updates = {
            self.statusLabel.text = self.statusText
            self.statusDot.backgroundColor = self.statusColor

            self.voiceTitleLabel.text = self.voiceTitle
            self.voiceTitleLabel.textColor = self.voiceTitleColor
            self.voiceIconView.image = UIImage(systemName: self.voiceIconName)
            let showsSpinner = isSendingState || (!isRecordingState && (self.isStartRequestInFlight || self.isOpeningHostApp))
            self.voiceIconView.alpha = (isRecordingState || showsSpinner) ? 0 : 1
            self.voicePrint.alpha = isRecordingState ? 1 : 0
            self.voiceSpinner.alpha = showsSpinner ? 1 : 0

            let acceptsVoiceTouch = !isSendingState || self.isVoicePressActive
            self.voiceButton.isEnabled = acceptsVoiceTouch
            self.voiceButton.accessibilityValue = self.inputMode.title
            self.commandButton.isEnabled = !isSendingState || self.isCommandPressActive
            self.commandButton.alpha = self.commandButton.isEnabled ? 1 : 0.45
            self.inputModeSwitch.setEnabled(!isRecordingState && !isSendingState && !self.isStartRequestInFlight)
            self.voiceButton.layer.shadowColor = self.voiceShadowColor.cgColor

            if showsSpinner {
                self.voiceSpinner.startAnimating()
            } else {
                self.voiceSpinner.stopAnimating()
            }
        }

        let gradientColors = voiceGradientColors.map { $0.cgColor }
        let shouldAnimate = animated && !isVoicePressActive && !isStartRequestInFlight
        if shouldAnimate {
            UIView.transition(with: voiceButton, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction], animations: updates)
            let anim = CABasicAnimation(keyPath: "colors")
            anim.fromValue = voiceGradient.colors
            anim.toValue = gradientColors
            anim.duration = 0.22
            voiceGradient.colors = gradientColors
            voiceGradient.add(anim, forKey: "colors")
        } else {
            updates()
            voiceGradient.colors = gradientColors
        }

        voicePrint.isActive = isRecordingState
        if isRecordingState {
            voicePrint.level = currentBridgeStatus?.audioLevel ?? 0
            startPulseRings()
        } else {
            stopPulseRings()
        }

        let desiredInterval: TimeInterval = isRecordingState ? 0.12 : 0.35
        if statusTimer != nil, abs(statusTimerInterval - desiredInterval) > 0.01 {
            stopStatusPolling()
            startStatusPolling(interval: desiredInterval)
        }
    }

    private func startPulseRings() {
        let tint = pulseRingColor.cgColor
        for (i, ring) in pulseRings.enumerated() where ring.animation(forKey: "pulse.scale") == nil {
            ring.strokeColor = tint
            ring.opacity = 0

            let begin = CACurrentMediaTime() + Double(i) * 0.6

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 1.7
            scale.duration = 1.8
            scale.beginTime = begin
            scale.repeatCount = .infinity
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.0, 0.55, 0.0]
            opacity.keyTimes = [0.0, 0.15, 1.0]
            opacity.duration = 1.8
            opacity.beginTime = begin
            opacity.repeatCount = .infinity

            ring.add(scale, forKey: "pulse.scale")
            ring.add(opacity, forKey: "pulse.opacity")
        }
    }

    private func stopPulseRings() {
        for ring in pulseRings {
            ring.removeAllAnimations()
            ring.opacity = 0
        }
    }

    private func attachPressAnimation(_ control: UIControl) {
        control.addTarget(self, action: #selector(controlPressDown(_:)), for: [.touchDown, .touchDragEnter])
        control.addTarget(self, action: #selector(controlPressUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    @objc private func controlPressDown(_ sender: UIControl) {
        UIView.animate(withDuration: 0.10, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            sender.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
            sender.alpha = 0.88
        }
    }

    @objc private func controlPressUp(_ sender: UIControl) {
        UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]) {
            sender.transform = .identity
            sender.alpha = 1
        }
    }

    @objc private func voicePressDown() {
        kbLog.notice("voicePressDown fired (bounds=\(NSCoder.string(for: self.voiceButton.bounds), privacy: .public))")
        guard !isVoicePressActive else { return }
        isVoicePressActive = true
        voicePressBeganAt = Date().timeIntervalSince1970
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.voiceButton.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }
        switch inputMode {
        case .hold:
            beginDictationPress()
        case .tap:
            handleTapModePress()
        }
    }

    @objc private func voicePressUp() {
        kbLog.notice("voicePressUp fired")
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.5, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.voiceButton.transform = .identity
        }
        switch inputMode {
        case .hold:
            endDictationPress()
        case .tap:
            isVoicePressActive = false
        }
    }

    @objc private func voicePressCancelled() {
        kbLog.notice("voicePressCancelled fired")
        let wasActive = isVoicePressActive
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.voiceButton.transform = .identity
        }
        if wasActive, inputMode == .hold, hasFullAccess {
            cancelActiveHoldRecording()
        }
        isVoicePressActive = false
    }

    @objc private func commandPressDown() {
        guard !isCommandPressActive else { return }
        isCommandPressActive = true
        voicePressBeganAt = Date().timeIntervalSince1970
        UIView.animate(withDuration: 0.10, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.commandButton.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            self.commandButton.alpha = 0.88
        }
        switch inputMode {
        case .hold:
            beginCommandPress()
        case .tap:
            handleCommandTapModePress()
        }
    }

    @objc private func commandPressUp() {
        UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.commandButton.transform = .identity
            self.commandButton.alpha = 1
        }
        switch inputMode {
        case .hold:
            endCommandPress()
        case .tap:
            isCommandPressActive = false
        }
    }

    @objc private func commandPressCancelled() {
        let wasActive = isCommandPressActive
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.commandButton.transform = .identity
            self.commandButton.alpha = 1
        }
        if wasActive, inputMode == .hold, hasFullAccess {
            cancelActiveHoldRecording()
        }
        isCommandPressActive = false
    }

    private func beginDictationPress() {
        kbLog.notice("beginDictationPress: fullAccess=\(self.hasFullAccess, privacy: .public), bridgeState=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public), awake=\(self.isBridgeAwake, privacy: .public)")
        lightHaptic()
        guard hasFullAccess else {
            kbLog.notice("beginDictationPress: no full access")
            isVoicePressActive = false
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        guard currentBridgeStatus?.state != .sending else {
            kbLog.notice("beginDictationPress: sending in flight, ignore")
            isVoicePressActive = false
            return
        }
        guard currentBridgeStatus?.state != .recording else {
            kbLog.notice("beginDictationPress: already recording; release will stop")
            return
        }
        cancelScheduledStop()
        let repairTarget = selectedTextRewriteTarget()
        beginDictationFromKeyboard(
            textEditContext: repairTarget.map { keyboardTextEditContext(intent: .repairSelection, target: $0) },
            target: repairTarget
        )
    }

    private func endDictationPress() {
        guard isVoicePressActive else { return }
        guard hasFullAccess else { return }
        let elapsed = Date().timeIntervalSince1970 - voicePressBeganAt
        guard elapsed >= minimumIntentReleaseDuration else {
            kbLog.notice("endDictationPress: cancelling early release after \(elapsed, privacy: .public)s")
            isVoicePressActive = false
            cancelActiveHoldRecording()
            return
        }

        isVoicePressActive = false
        if isStartRequestInFlight {
            shouldStopWhenStartCompletes = true
            return
        }
        guard currentBridgeStatus?.state == .recording else { return }
        stopDictationAfterMinimumHoldIfNeeded()
    }

    private func handleTapModePress() {
        kbLog.notice("handleTapModePress: fullAccess=\(self.hasFullAccess, privacy: .public), bridgeState=\(self.currentBridgeStatus?.state.rawValue ?? "nil", privacy: .public), awake=\(self.isBridgeAwake, privacy: .public)")
        lightHaptic()
        guard hasFullAccess else {
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        if isStartRequestInFlight {
            kbLog.notice("handleTapModePress: start already in flight; ignoring")
            return
        }
        if tapRecordingActive || currentBridgeStatus?.state == .recording {
            cancelScheduledStop()
            tapRecordingActive = false
            kbLog.notice("handleTapModePress: sending .stop command")
            sendBridgeCommand(.stop)
            return
        }
        guard currentBridgeStatus?.state != .sending else { return }
        cancelScheduledStop()
        tapRecordingActive = true
        let repairTarget = selectedTextRewriteTarget()
        beginDictationFromKeyboard(
            textEditContext: repairTarget.map { keyboardTextEditContext(intent: .repairSelection, target: $0) },
            target: repairTarget
        )
    }

    private func beginCommandPress() {
        lightHaptic()
        guard hasFullAccess else {
            isCommandPressActive = false
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        guard currentBridgeStatus?.state != .sending else {
            isCommandPressActive = false
            return
        }
        guard currentBridgeStatus?.state != .recording else { return }
        guard let target = currentTextRewriteTarget(),
              !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            isCommandPressActive = false
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Select text first.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        cancelScheduledStop()
        beginDictationFromKeyboard(
            textEditContext: keyboardTextEditContext(intent: .command, target: target),
            target: target
        )
    }

    private func endCommandPress() {
        guard isCommandPressActive else { return }
        guard hasFullAccess else { return }
        let elapsed = Date().timeIntervalSince1970 - voicePressBeganAt
        guard elapsed >= minimumIntentReleaseDuration else {
            isCommandPressActive = false
            cancelActiveHoldRecording()
            return
        }

        isCommandPressActive = false
        if isStartRequestInFlight {
            shouldStopWhenStartCompletes = true
            return
        }
        guard currentBridgeStatus?.state == .recording else { return }
        stopDictationAfterMinimumHoldIfNeeded()
    }

    private func handleCommandTapModePress() {
        lightHaptic()
        guard hasFullAccess else {
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        if isStartRequestInFlight { return }
        if tapRecordingActive || currentBridgeStatus?.state == .recording {
            cancelScheduledStop()
            tapRecordingActive = false
            sendBridgeCommand(.stop)
            return
        }
        guard currentBridgeStatus?.state != .sending else { return }
        guard let target = currentTextRewriteTarget(),
              !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Select text first.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        cancelScheduledStop()
        tapRecordingActive = true
        beginDictationFromKeyboard(
            textEditContext: keyboardTextEditContext(intent: .command, target: target),
            target: target
        )
    }

    private func beginDictationFromKeyboard(
        textEditContext: KeyboardTextEditContext? = nil,
        target: TextRewriteTarget? = nil
    ) {
        guard !isStartRequestInFlight else { return }
        activeRecordingTextTarget = target
        guard isBridgeAwake else {
            probeBridgeThenBeginDictation(textEditContext: textEditContext, target: target)
            return
        }

        startDictationCommand(textEditContext: textEditContext, target: target)
    }

    private func probeBridgeThenBeginDictation(
        textEditContext: KeyboardTextEditContext?,
        target: TextRewriteTarget?
    ) {
        kbLog.notice("probeBridgeThenBeginDictation: checking local keyboard server before opening host")
        isStartRequestInFlight = true
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        bridgeStatus = KeyboardBridgeStatus(state: .standby, message: "Checking Typeforme")
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()

        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.status(timeout: 0.9)
                await MainActor.run {
                    self.isStartRequestInFlight = false
                    self.bridgeStatus = status
                    self.lastBridgeContactAt = Date().timeIntervalSince1970

                    guard status.state != .idle else {
                        guard self.shouldContinueAfterBridgeProbe() else {
                            self.updateUI()
                            return
                        }
                        self.openHostForDictation()
                        return
                    }

                    if status.state == .recording {
                        if self.inputMode == .tap {
                            self.tapRecordingActive = false
                            self.sendBridgeCommand(.stop)
                        } else if !self.isVoicePressActive {
                            if self.shouldCancelWhenStartCompletes {
                                self.shouldCancelWhenStartCompletes = false
                                self.sendBridgeCommand(.cancel)
                            } else if self.shouldStopWhenStartCompletes {
                                self.shouldStopWhenStartCompletes = false
                                self.stopDictationAfterMinimumHoldIfNeeded()
                            } else {
                                self.updateUI()
                            }
                        } else {
                            self.updateUI()
                        }
                        return
                    }

                    guard self.shouldContinueAfterBridgeProbe() else {
                        self.updateUI()
                        return
                    }
                    self.startDictationCommand(textEditContext: textEditContext, target: target)
                }
            } catch {
                await MainActor.run {
                    self.isStartRequestInFlight = false
                    guard self.shouldContinueAfterBridgeProbe() else {
                        self.updateUI()
                        return
                    }
                    self.openHostForDictation()
                }
            }
        }
    }

    private func shouldContinueAfterBridgeProbe() -> Bool {
        guard inputMode == .hold else { return true }
        if isVoicePressActive || isCommandPressActive { return true }
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        tapRecordingActive = false
        activeRecordingTextTarget = nil
        return false
    }

    private func openHostForDictation() {
        kbLog.notice("openHostForDictation: bridge unavailable — waking host app")
        isStartRequestInFlight = false
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        if inputMode == .tap {
            tapRecordingActive = false
        }
        isVoicePressActive = false
        isCommandPressActive = false
        activeRecordingTextTarget = nil
        openHostAppForKeyboardAction(
            "standby",
            returnToKeyboard: true,
            openingMessage: "Opening Typeforme to prepare dictation."
        )
    }

    private func startDictationCommand(
        textEditContext: KeyboardTextEditContext? = nil,
        target: TextRewriteTarget? = nil
    ) {
        kbLog.notice("beginDictationFromKeyboard: sending .start command")
        isStartRequestInFlight = true
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        activeRecordingTextTarget = target
        let command = KeyboardBridgeCommand(
            action: .start,
            correctionMode: correctionMode.rawValue,
            textEditContext: textEditContext,
            dictationContext: textEditContext == nil ? currentDictationContext() : nil
        )
        sendBridgeCommand(command)
    }

    private func finishStartRequestIfNeeded(status: KeyboardBridgeStatus?) {
        isStartRequestInFlight = false
        if shouldCancelWhenStartCompletes {
            shouldCancelWhenStartCompletes = false
            shouldStopWhenStartCompletes = false
            if status?.state == .recording || currentBridgeStatus?.state == .recording {
                sendBridgeCommand(.cancel)
            }
            activeRecordingTextTarget = nil
            return
        }
        guard shouldStopWhenStartCompletes else { return }
        shouldStopWhenStartCompletes = false
        if status?.state == .recording || currentBridgeStatus?.state == .recording {
            stopDictationAfterMinimumHoldIfNeeded()
        }
    }

    private func cancelActiveHoldRecording() {
        tapRecordingActive = false
        isCommandPressActive = false
        if isStartRequestInFlight {
            shouldCancelWhenStartCompletes = true
            shouldStopWhenStartCompletes = false
            return
        }
        if currentBridgeStatus?.state == .recording {
            sendBridgeCommand(.cancel)
        }
        activeRecordingTextTarget = nil
    }

    private func stopDictationAfterMinimumHoldIfNeeded() {
        cancelScheduledStop()
        tapRecordingActive = false
        isCommandPressActive = false
        guard currentBridgeStatus?.state == .recording else { return }
        let elapsed = Date().timeIntervalSince1970 - voicePressBeganAt
        let delay = max(0, minimumHoldRecordingDuration - elapsed)
        guard delay > 0 else {
            kbLog.notice("stopDictationAfterMinimumHoldIfNeeded: sending .stop command")
            sendBridgeCommand(.stop)
            return
        }

        kbLog.notice("stopDictationAfterMinimumHoldIfNeeded: delaying stop by \(delay, privacy: .public)s")
        scheduledStopTask = Task { [weak self] in
            let nanos = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            await MainActor.run {
                guard let self, self.currentBridgeStatus?.state == .recording else { return }
                self.scheduledStopTask = nil
                kbLog.notice("stopDictationAfterMinimumHoldIfNeeded: delayed .stop command")
                self.sendBridgeCommand(.stop)
            }
        }
    }

    private func cancelScheduledStop() {
        scheduledStopTask?.cancel()
        scheduledStopTask = nil
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
    }

    private func openStandbyInHostApp(returnToKeyboard: Bool = true) {
        openHostAppForKeyboardAction(
            "standby",
            returnToKeyboard: returnToKeyboard,
            openingMessage: "Opening Typeforme to prepare dictation."
        )
    }

    private func openHostAppForKeyboardAction(
        _ action: String,
        returnToKeyboard: Bool,
        openingMessage: String
    ) {
        var components = URLComponents()
        components.scheme = "typeforme"
        components.host = action
        var queryItems = [
            URLQueryItem(name: "source", value: "keyboard"),
            URLQueryItem(name: "return", value: returnToKeyboard ? "1" : "0"),
            URLQueryItem(name: "correction_mode", value: correctionMode.rawValue),
        ]
        let returnBundleID = currentHostBundleID
        let returnProcessID = currentHostProcessID
        writeHostWakeRequest(
            action: action,
            returnToKeyboard: returnToKeyboard,
            returnBundleID: returnBundleID,
            returnProcessID: returnProcessID
        )
        if let returnBundleID {
            kbLog.notice("openHostAppForKeyboardAction: captured return bundle \(returnBundleID, privacy: .public)")
            queryItems.append(URLQueryItem(name: "return_bundle", value: returnBundleID))
        } else {
            kbLog.notice("openHostAppForKeyboardAction: no return bundle available")
        }
        if let returnProcessID {
            kbLog.notice("openHostAppForKeyboardAction: captured return pid \(returnProcessID, privacy: .public)")
            queryItems.append(URLQueryItem(name: "return_pid", value: String(returnProcessID)))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return }
        kbLog.notice("openHostAppForKeyboardAction: attempting to open \(url.absoluteString, privacy: .public); extensionContext=\(self.extensionContext != nil, privacy: .public)")
        openingHostUntil = Date().timeIntervalSince1970 + 8
        bridgeStatus = KeyboardBridgeStatus(state: .standby, message: openingMessage)
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
        openHostApp(url) { [weak self] success in
            kbLog.notice("openHostAppForKeyboardAction: open completion success=\(success, privacy: .public)")
            guard let self, !success else { return }
            self.openingHostUntil = 0
            self.tapRecordingActive = false
            self.bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Open Typeforme once to prepare dictation.")
            self.lastBridgeContactAt = 0
            self.updateUI()
        }
    }

    private func openHostApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        if let extensionContext {
            kbLog.notice("openHostApp: opening via extensionContext.open")
            extensionContext.open(url) { [weak self] success in
                kbLog.notice("openHostApp: extensionContext.open completion success=\(success, privacy: .public)")
                if success {
                    completion(true)
                    return
                }
                completion(self?.openHostAppViaApplicationWorkspace(url) ?? false)
            }
            return
        }
        kbLog.notice("openHostApp: extensionContext unavailable; using LSApplicationWorkspace")
        completion(openHostAppViaApplicationWorkspace(url))
    }

    private func openHostAppViaApplicationWorkspace(_ url: URL) -> Bool {
        guard let workspaceClass = objc_getClass("LSApplicationWorkspace") as? AnyObject else {
            kbLog.notice("openHostAppViaApplicationWorkspace: LSApplicationWorkspace unavailable")
            return false
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as? NSObject else {
            kbLog.notice("openHostAppViaApplicationWorkspace: defaultWorkspace unavailable")
            return false
        }

        let openSensitiveSelector = NSSelectorFromString("openSensitiveURL:withOptions:")
        if workspace.responds(to: openSensitiveSelector) {
            kbLog.notice("openHostAppViaApplicationWorkspace: opening standby URL via openSensitiveURL")
            _ = workspace.perform(openSensitiveSelector, with: url as NSURL, with: NSDictionary())
            return true
        }

        let openURLSelector = NSSelectorFromString("openURL:")
        if workspace.responds(to: openURLSelector) {
            kbLog.notice("openHostAppViaApplicationWorkspace: opening standby URL via openURL")
            _ = workspace.perform(openURLSelector, with: url as NSURL)
            return true
        }

        let openBundleSelector = NSSelectorFromString("openApplicationWithBundleID:")
        if workspace.responds(to: openBundleSelector) {
            kbLog.notice("openHostAppViaApplicationWorkspace: opening host bundle without URL")
            _ = workspace.perform(openBundleSelector, with: "com.btcdtc.typeforme")
            return true
        }

        kbLog.notice("openHostAppViaApplicationWorkspace: no usable open selector")
        return false
    }

    private var currentHostBundleID: String? {
        if let id = privateStringValue(named: "_hostApplicationBundleIdentifier", from: self),
           isUsableReturnBundleID(id) {
            kbLog.notice("currentHostBundleID: resolved via _hostApplicationBundleIdentifier: \(id, privacy: .public)")
            return id
        }
        if let id = privateStringValue(named: "_hostBundleID", from: parent),
           isUsableReturnBundleID(id) {
            kbLog.notice("currentHostBundleID: resolved via _hostBundleID: \(id, privacy: .public)")
            return id
        }
        if let id = currentHostBundleIDFromHostPID,
           isUsableReturnBundleID(id) {
            kbLog.notice("currentHostBundleID: resolved via host pid: \(id, privacy: .public)")
            return id
        }
        kbLog.notice("currentHostBundleID unavailable")
        return nil
    }

    private var currentHostBundleIDFromHostPID: String? {
        guard let pid = currentHostProcessID else {
            kbLog.notice("currentHostBundleIDFromHostPID: _hostPID unavailable")
            return nil
        }

        let hostPID: AnyObject = NSNumber(value: pid)
        if let id = currentHostBundleIDFromXPC(hostPID: hostPID) {
            kbLog.notice("currentHostBundleIDFromHostPID: resolved via XPC: \(id, privacy: .public)")
            return id
        }

        kbLog.notice("currentHostBundleIDFromHostPID: unresolved for pid=\(pid, privacy: .public)")
        return nil
    }

    private var currentHostProcessID: Int32? {
        if let number = privateIntMethodValue(named: "_hostProcessIdentifier", from: self),
           number.int32Value > 0 {
            return number.int32Value
        }
        guard let hostPID = privateObjectValue(named: "_hostPID", from: parent) else {
            return nil
        }
        guard let pid = intValue(from: hostPID), pid > 0 else {
            kbLog.notice("currentHostProcessID: invalid _hostPID \(String(describing: hostPID), privacy: .public)")
            return nil
        }
        return pid
    }

    private func currentHostBundleIDFromXPC(hostPID: AnyObject) -> String? {
        guard let serviceClass = NSClassFromString("PKService") else {
            kbLog.notice("currentHostBundleIDFromXPC: PKService unavailable")
            return nil
        }
        let serviceObject = serviceClass as AnyObject

        let defaultServiceSelector = NSSelectorFromString("defaultService")
        guard serviceObject.responds(to: defaultServiceSelector),
              let service = serviceObject.perform(defaultServiceSelector)?.takeUnretainedValue() as? NSObject
        else {
            kbLog.notice("currentHostBundleIDFromXPC: defaultService unavailable")
            return nil
        }

        let personalitiesSelector = NSSelectorFromString("personalities")
        guard service.responds(to: personalitiesSelector),
              let personalities = service.perform(personalitiesSelector)?.takeUnretainedValue() as? NSDictionary
        else {
            kbLog.notice("currentHostBundleIDFromXPC: personalities unavailable")
            return nil
        }

        let extensionBundleIDs = [
            Bundle.main.bundleIdentifier,
            Bundle(for: type(of: self)).bundleIdentifier,
        ].compactMap { $0 }

        for extensionBundleID in extensionBundleIDs {
            guard let infos = personalities.object(forKey: extensionBundleID) as? NSDictionary,
                  let info = infos.object(forKey: hostPID) as? NSObject,
                  let connection = privateObjectValue(named: "connection", from: info),
                  let xpcConnection = privateObjectValue(named: "_xpcConnection", from: connection)
            else { continue }

            guard let bundleID = copyBundleID(fromXPCConnection: xpcConnection) else {
                kbLog.notice("currentHostBundleIDFromXPC: xpc bundle id unavailable for \(extensionBundleID, privacy: .public)")
                continue
            }
            return bundleID
        }

        kbLog.notice("currentHostBundleIDFromXPC: no personality matched host pid")
        return nil
    }

    private func copyBundleID(fromXPCConnection connection: AnyObject) -> String? {
        guard let handle = dlopen(nil, RTLD_NOW) else {
            kbLog.notice("copyBundleIDFromXPCConnection: dlopen unavailable")
            return nil
        }

        guard let symbol = dlsym(handle, "xpc_connection_copy_bundle_id") else {
            kbLog.notice("copyBundleIDFromXPCConnection: symbol unavailable")
            return nil
        }

        typealias CopyBundleID = @convention(c) (AnyObject) -> UnsafePointer<CChar>?
        let copyBundleID = unsafeBitCast(symbol, to: CopyBundleID.self)
        guard let cString = copyBundleID(connection) else { return nil }
        return String(cString: cString)
    }

    private func writeHostWakeRequest(
        action: String,
        returnToKeyboard: Bool,
        returnBundleID: String?,
        returnProcessID: Int32?
    ) {
        guard hasFullAccess else {
            kbLog.notice("writeHostWakeRequest: skipped without full access")
            return
        }
        var payload: [String: Any] = [
            "version": 1,
            "id": UUID().uuidString,
            "created_at": Date().timeIntervalSince1970,
            "source": "keyboard",
            "action": action,
            "return": returnToKeyboard,
            "correction_mode": correctionMode.rawValue,
        ]
        if let returnBundleID {
            payload["return_bundle"] = returnBundleID
        }
        if let returnProcessID {
            payload["return_pid"] = returnProcessID
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8),
              let pasteboard = UIPasteboard(name: hostWakePasteboardName, create: true)
        else {
            kbLog.notice("writeHostWakeRequest: failed to encode request")
            return
        }
        pasteboard.string = text
        kbLog.notice("writeHostWakeRequest: wrote action=\(action, privacy: .public), return=\(returnToKeyboard, privacy: .public), bundle=\(returnBundleID ?? "nil", privacy: .public), pid=\(returnProcessID.map(String.init) ?? "nil", privacy: .public)")
    }

    private func intValue(from object: AnyObject) -> Int32? {
        if let number = object as? NSNumber {
            return number.int32Value
        }
        let text = String(describing: object).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(text)
    }

    private func isUsableReturnBundleID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "<null>" else { return false }
        guard isBundleIdentifierShape(trimmed) else { return false }
        guard trimmed != Bundle.main.bundleIdentifier else { return false }
        guard !trimmed.hasPrefix("com.typeforme.") else { return false }
        guard !trimmed.hasPrefix("com.btcdtc.typeforme") else { return false }
        return true
    }

    private func isBundleIdentifierShape(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for part in parts {
            guard !part.isEmpty else { return false }
            guard part.allSatisfy({ character in
                character.isLetter || character.isNumber || character == "-"
            }) else { return false }
        }
        return true
    }

    private func privateStringValue(named name: String, from object: AnyObject?) -> String? {
        guard let value = privateObjectValue(named: name, from: object) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        let text = String(describing: value)
        return text == "<null>" ? nil : text
    }

    private func privateObjectValue(named name: String, from object: AnyObject?) -> AnyObject? {
        guard let object else { return nil }
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector) {
            if let returnTypeText = methodReturnType(named: selector, from: object) {
                if returnTypeText.hasPrefix("@") || returnTypeText == "#" {
                    return object.perform(selector)?.takeUnretainedValue()
                }
                return privateIntMethodValue(named: name, from: object)
            }
            return object.perform(selector)?.takeUnretainedValue()
        }

        var nextClass: AnyClass? = object_getClass(object)
        while let currentClass = nextClass {
            if let ivar = class_getInstanceVariable(currentClass, name) {
                return privateIvarValue(ivar, from: object)
            }
            nextClass = class_getSuperclass(currentClass)
        }
        return nil
    }

    private func privateIntMethodValue(named name: String, from object: AnyObject?) -> NSNumber? {
        guard let object else { return nil }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let returnTypeText = methodReturnType(named: selector, from: object),
              let imp = object.method(for: selector)
        else { return nil }

        switch returnTypeText {
        case "i":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
            let getter = unsafeBitCast(imp, to: Getter.self)
            return NSNumber(value: getter(object, selector))
        case "I":
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt32
            let getter = unsafeBitCast(imp, to: Getter.self)
            return NSNumber(value: getter(object, selector))
        case "q":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int64
            let getter = unsafeBitCast(imp, to: Getter.self)
            return NSNumber(value: getter(object, selector))
        case "Q":
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt64
            let getter = unsafeBitCast(imp, to: Getter.self)
            return NSNumber(value: getter(object, selector))
        case "s":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int16
            let getter = unsafeBitCast(imp, to: Getter.self)
            return NSNumber(value: getter(object, selector))
        case "S":
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt16
            let getter = unsafeBitCast(imp, to: Getter.self)
            return NSNumber(value: getter(object, selector))
        case "c", "B":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            let getter = unsafeBitCast(imp, to: Getter.self)
            return NSNumber(value: getter(object, selector))
        default:
            return nil
        }
    }

    private func methodReturnType(named selector: Selector, from object: AnyObject) -> String? {
        guard let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2
        else { return nil }
        let returnType = method_copyReturnType(method)
        let returnTypeText = String(cString: returnType)
        free(returnType)
        return returnTypeText
    }

    private func privateIvarValue(_ ivar: Ivar, from object: AnyObject) -> AnyObject? {
        guard let typeEncoding = ivar_getTypeEncoding(ivar) else { return nil }
        let type = String(cString: typeEncoding)
        if type.hasPrefix("@") {
            return object_getIvar(object, ivar) as AnyObject?
        }

        let offset = ivar_getOffset(ivar)
        let rawPointer = Unmanaged.passUnretained(object).toOpaque().advanced(by: offset)
        switch type {
        case "i":
            return NSNumber(value: rawPointer.load(as: Int32.self))
        case "I":
            return NSNumber(value: rawPointer.load(as: UInt32.self))
        case "q":
            return NSNumber(value: rawPointer.load(as: Int64.self))
        case "Q":
            return NSNumber(value: rawPointer.load(as: UInt64.self))
        case "s":
            return NSNumber(value: rawPointer.load(as: Int16.self))
        case "S":
            return NSNumber(value: rawPointer.load(as: UInt16.self))
        case "c", "B":
            return NSNumber(value: rawPointer.load(as: Bool.self))
        default:
            kbLog.notice("privateIvarValue: unsupported ivar type \(type, privacy: .public)")
            return nil
        }
    }

    @objc private func openHostFromSettingsButton() {
        lightHaptic()
        openStandbyInHostApp(returnToKeyboard: false)
    }

    @objc private func pasteResult() {
        lightHaptic()
        guard hasFullAccess else { return }
        let candidates = [
            UIPasteboard.general.string,
            defaults.string(forKey: lastInsertedTextKey),
        ]
        guard let text = candidates.compactMap({ $0 }).first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return }
        textDocumentProxy.insertText(text)
        defaults.set(text, forKey: lastInsertedTextKey)
    }

    @objc private func selectCorrectionModeButton(_ sender: UIButton) {
        guard let preset = correctionModeButtons.first(where: { $0.button === sender })?.preset else { return }
        correctionMode = preset
        hasUserSelectedCorrectionMode = true
        lightHaptic()
        updateUI()
        rewriteCurrentInputOrPasteboard(using: preset)
    }

    private func updateCorrectionModeButtons() {
        let isEnabled = currentBridgeStatus?.state != .recording
            && currentBridgeStatus?.state != .sending
            && !isStartRequestInFlight
            && styleRewriteCommandID == nil
        let signature = [
            correctionMode.rawValue,
            isEnabled ? "enabled" : "disabled",
            isKeyboardDark ? "dark" : "light",
        ].joined(separator: ":")
        guard signature != lastCorrectionModeButtonSignature else { return }
        lastCorrectionModeButtonSignature = signature
        for item in correctionModeButtons {
            let isSelected = item.preset == correctionMode
            let configuration = correctionModeButtonConfiguration(title: item.preset.title, selected: isSelected)
            item.button.configuration = configuration
            item.button.isEnabled = isEnabled
            item.button.alpha = isEnabled ? 1 : 0.45
            item.button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    private func rewriteCurrentInputOrPasteboard(using preset: CorrectionModePreset) {
        guard hasFullAccess else {
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Enable Full Access in iOS keyboard settings.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        guard styleRewriteCommandID == nil,
              currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending
        else { return }
        guard let target = currentTextRewriteTarget(),
              !target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            bridgeStatus = KeyboardBridgeStatus(state: .error, message: "Nothing to rewrite.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }

        let command = KeyboardBridgeCommand(
            action: .restyleText,
            correctionMode: preset.rawValue,
            text: target.text
        )
        styleRewriteCommandID = command.id
        bridgeStatus = KeyboardBridgeStatus(commandID: command.id, state: .sending, message: "Rewriting")
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()

        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.send(command, timeout: KeyboardBridgeCommandAction.restyleText.requestTimeout)
                await MainActor.run {
                    self.finishStyleRewrite(status: status, target: target, commandID: command.id)
                }
            } catch {
                await MainActor.run {
                    guard self.styleRewriteCommandID == command.id else { return }
                    self.styleRewriteCommandID = nil
                    self.bridgeStatus = KeyboardBridgeStatus(commandID: command.id, state: .error, message: "Open Typeforme once to prepare rewriting.")
                    self.lastBridgeContactAt = 0
                    self.updateUI()
                }
            }
        }
    }

    private func currentTextRewriteTarget() -> TextRewriteTarget? {
        if let selected = textDocumentProxy.selectedText,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return captureSelectionTarget(selected)
        }

        if let recentSelection = recentSelectionTargetIfFresh() {
            kbLog.notice("using cached selection target for command")
            return recentSelection
        }

        if let contextTarget = currentExpandedContextRewriteTarget() {
            return contextTarget
        }

        if let result = currentBridgeStatus?.resultText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !result.isEmpty {
            return .cachedResult(result)
        }

        if let lastInserted = defaults.string(forKey: lastInsertedTextKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lastInserted.isEmpty {
            return .cachedResult(lastInserted)
        }

        if let clipboard = UIPasteboard.general.string,
           !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .pasteboard(clipboard)
        }
        return nil
    }

    private func currentExpandedContextRewriteTarget() -> TextRewriteTarget? {
        let initialBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let initialAfter = textDocumentProxy.documentContextAfterInput ?? ""
        guard !(initialBefore + initialAfter).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let before = expandedContextBefore(startingWith: initialBefore)
        let after = expandedContextAfter(startingWith: initialAfter)
        kbLog.notice("context rewrite target captured: initialBeforeLen=\(initialBefore.count, privacy: .public), initialAfterLen=\(initialAfter.count, privacy: .public), beforeLen=\(before.count, privacy: .public), afterLen=\(after.count, privacy: .public)")
        return .context(before: before, after: after)
    }

    private func expandedContextBefore(startingWith initialBefore: String) -> String {
        var before = initialBefore
        var chunk = initialBefore
        var moved = 0
        var steps = 0

        while !chunk.isEmpty,
              before.count < Self.textRewriteContextExpansionLimit,
              steps < Self.textRewriteContextExpansionMaxSteps {
            let snapshotBefore = textDocumentProxy.documentContextBeforeInput ?? ""
            let snapshotAfter = textDocumentProxy.documentContextAfterInput ?? ""
            let offset = -chunk.count
            textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            moved += chunk.count
            let nextBefore = textDocumentProxy.documentContextBeforeInput ?? ""
            let nextAfter = textDocumentProxy.documentContextAfterInput ?? ""
            guard nextBefore != snapshotBefore || nextAfter != snapshotAfter else { break }

            steps += 1
            chunk = nextBefore
            guard !chunk.isEmpty else { break }
            before = chunk + before
            if before.count > Self.textRewriteContextExpansionLimit {
                before = String(before.suffix(Self.textRewriteContextExpansionLimit))
                break
            }
        }

        if moved > 0 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: moved)
        }
        return before
    }

    private func expandedContextAfter(startingWith initialAfter: String) -> String {
        var after = initialAfter
        var chunk = initialAfter
        var moved = 0
        var steps = 0

        while !chunk.isEmpty,
              after.count < Self.textRewriteContextExpansionLimit,
              steps < Self.textRewriteContextExpansionMaxSteps {
            let snapshotBefore = textDocumentProxy.documentContextBeforeInput ?? ""
            let snapshotAfter = textDocumentProxy.documentContextAfterInput ?? ""
            textDocumentProxy.adjustTextPosition(byCharacterOffset: chunk.count)
            moved += chunk.count
            let nextBefore = textDocumentProxy.documentContextBeforeInput ?? ""
            let nextAfter = textDocumentProxy.documentContextAfterInput ?? ""
            guard nextBefore != snapshotBefore || nextAfter != snapshotAfter else { break }

            steps += 1
            chunk = nextAfter
            guard !chunk.isEmpty else { break }
            after += chunk
            if after.count > Self.textRewriteContextExpansionLimit {
                after = String(after.prefix(Self.textRewriteContextExpansionLimit))
                break
            }
        }

        if moved > 0 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: -moved)
        }
        return after
    }

    private func selectedTextRewriteTarget() -> TextRewriteTarget? {
        if let selected = textDocumentProxy.selectedText,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return captureSelectionTarget(selected)
        }

        if let recentSelection = recentSelectionTargetIfFresh() {
            kbLog.notice("using cached selection target for repair")
            return recentSelection
        }
        return nil
    }

    private func captureSelectionTarget(_ selected: String) -> TextRewriteTarget {
        let target = TextRewriteTarget.selection(
            text: selected,
            contextBefore: textDocumentProxy.documentContextBeforeInput ?? "",
            contextAfter: textDocumentProxy.documentContextAfterInput ?? ""
        )
        recentSelectionTarget = target
        recentSelectionCapturedAt = Date().timeIntervalSince1970
        return target
    }

    private func refreshSelectionSnapshot() {
        guard let selected = textDocumentProxy.selectedText,
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        _ = captureSelectionTarget(selected)
    }

    private func recentSelectionTargetIfFresh() -> TextRewriteTarget? {
        guard let recentSelectionTarget else { return nil }
        guard Date().timeIntervalSince1970 - recentSelectionCapturedAt <= selectionSnapshotTTL else {
            return nil
        }
        return recentSelectionTarget
    }

    private func keyboardTextEditContext(
        intent: KeyboardTextEditIntent,
        target: TextRewriteTarget
    ) -> KeyboardTextEditContext {
        switch target {
        case .selection(let text, let contextBefore, let contextAfter):
            return KeyboardTextEditContext(
                intent: intent,
                contextBefore: contextBefore,
                targetText: text,
                contextAfter: contextAfter
            )
        case .context(let before, let after):
            return KeyboardTextEditContext(
                intent: intent,
                contextBefore: "",
                targetText: before + after,
                contextAfter: ""
            )
        case .cachedResult(let text), .pasteboard(let text):
            return KeyboardTextEditContext(
                intent: intent,
                contextBefore: "",
                targetText: text,
                contextAfter: ""
            )
        }
    }

    private func currentDictationContext() -> KeyboardDictationContext? {
        let before = limitedContextBefore(textDocumentProxy.documentContextBeforeInput ?? "")
        let after = limitedContextAfter(textDocumentProxy.documentContextAfterInput ?? "")
        guard !(before + after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return KeyboardDictationContext(contextBefore: before, contextAfter: after)
    }

    private func limitedContextBefore(_ text: String) -> String {
        guard text.count > Self.dictationContextLimit else { return text }
        return String(text.suffix(Self.dictationContextLimit))
    }

    private func limitedContextAfter(_ text: String) -> String {
        guard text.count > Self.dictationContextLimit else { return text }
        return String(text.prefix(Self.dictationContextLimit))
    }

    private func finishStyleRewrite(status: KeyboardBridgeStatus, target: TextRewriteTarget, commandID: String) {
        guard styleRewriteCommandID == commandID else { return }
        styleRewriteCommandID = nil
        guard status.state == .result,
              let text = status.resultText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            bridgeStatus = status.state == .error
                ? status
                : KeyboardBridgeStatus(commandID: commandID, state: .error, message: status.message)
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }

        guard applyRewrittenText(text, replacing: target) else {
            bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .error, message: "Selection changed; result copied.")
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
            return
        }
        defaults.set(commandID, forKey: lastInsertedCommandIDKey)
        defaults.set(text, forKey: lastInsertedTextKey)
        recentSelectionTarget = nil
        bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .result, message: "Rewritten", resultText: text)
        lastBridgeContactAt = Date().timeIntervalSince1970
        updateUI()
    }

    @discardableResult
    private func applyRewrittenText(_ text: String, replacing target: TextRewriteTarget) -> Bool {
        UIPasteboard.general.string = text
        switch target {
        case .selection(let original, let contextBefore, let contextAfter):
            guard applySelectionReplacement(
                text,
                replacing: original,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            ) else { return false }
        case .context(let before, let after):
            replaceContextText(text, before: before, after: after)
        case .cachedResult, .pasteboard:
            textDocumentProxy.insertText(text)
        }
        return true
    }

    private func applySelectionReplacement(
        _ text: String,
        replacing original: String,
        contextBefore: String,
        contextAfter: String
    ) -> Bool {
        if textDocumentProxy.selectedText == original {
            textDocumentProxy.insertText(text)
            return true
        }

        let currentBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let currentAfter = textDocumentProxy.documentContextAfterInput ?? ""
        if currentBefore.hasSuffix(original) {
            deleteBackward(characterCount: original.count)
            textDocumentProxy.insertText(text)
            return true
        }

        if currentBefore == contextBefore, currentAfter.hasPrefix(original) {
            replaceContextText(text, before: "", after: original)
            return true
        }

        kbLog.notice("selection replacement skipped: originalLen=\(original.count, privacy: .public), beforeLen=\(currentBefore.count, privacy: .public), afterLen=\(currentAfter.count, privacy: .public)")
        return false
    }

    private func replaceContextText(_ text: String, before: String, after: String) {
        guard !after.isEmpty else {
            deleteBackward(characterCount: before.count)
            textDocumentProxy.insertText(text)
            return
        }

        textDocumentProxy.adjustTextPosition(byCharacterOffset: after.count)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deleteBackward(characterCount: before.count + after.count)
            self.textDocumentProxy.insertText(text)
        }
    }

    private func deleteBackward(characterCount: Int) {
        guard characterCount > 0 else { return }
        for _ in 0..<characterCount {
            textDocumentProxy.deleteBackward()
        }
    }

    private func correctionModeButtonConfiguration(title: String, selected: Bool) -> UIButton.Configuration {
        var configuration: UIButton.Configuration = .filled()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 11, weight: .semibold)
            return outgoing
        }
        configuration.baseBackgroundColor = selected
            ? UIColor.label.withAlphaComponent(0.92)
            : UIColor.systemBackground.withAlphaComponent(isKeyboardDark ? 0.16 : 0.54)
        configuration.baseForegroundColor = selected ? .systemBackground : .secondaryLabel
        return configuration
    }

    private func selectInputMode(_ rawValue: String) {
        guard currentBridgeStatus?.state != .recording,
              currentBridgeStatus?.state != .sending,
              !isStartRequestInFlight,
              styleRewriteCommandID == nil
        else { return }
        guard let nextMode = VoiceInputMode(rawValue: rawValue) else { return }
        guard nextMode != inputMode else { return }
        inputMode = nextMode
        defaults.set(inputMode.rawValue, forKey: inputModeKey)
        lightHaptic()
        updateUI()
    }

    @objc private func deletePressDown() {
        guard deleteRepeatTask == nil else { return }
        textDocumentProxy.deleteBackward()
        deleteRepeatTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.deleteRepeatInitialDelay)
            while !Task.isCancelled {
                await MainActor.run {
                    self.textDocumentProxy.deleteBackward()
                }
                try? await Task.sleep(nanoseconds: self.deleteRepeatInterval)
            }
        }
    }

    @objc private func deletePressUp() {
        stopDeleteRepeat()
    }

    private func stopDeleteRepeat() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }

    @objc private func insertSpace() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func insertReturn() {
        textDocumentProxy.insertText("\n")
    }

    private func lightHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var currentBridgeStatus: KeyboardBridgeStatus? {
        bridgeStatus
    }

    private var isOpeningHostApp: Bool {
        openingHostUntil > Date().timeIntervalSince1970
    }

    private var isBridgeAwake: Bool {
        guard let status = currentBridgeStatus else { return false }
        guard Date().timeIntervalSince1970 - lastBridgeContactAt < 3 else { return false }
        return status.state != .idle
    }

    /// One short line, under the orb. Doubles as the only verbal hint — the
    /// orb's color and pulse rings carry the rest of the state.
    private var voiceTitle: String {
        if isOpeningHostApp { return "Opening Typeforme…" }
        switch currentBridgeStatus?.state {
        case .recording: return inputMode.recordingTitle
        case .sending: return "Transcribing"
        default: return inputMode.idleTitle
        }
    }

    private var voiceTitleColor: UIColor {
        return .label
    }

    private var pulseRingColor: UIColor {
        switch currentBridgeStatus?.state {
        case .recording: return UIColor.systemRed.withAlphaComponent(0.65)
        case .sending: return UIColor.systemIndigo.withAlphaComponent(0.5)
        default: return UIColor.systemBlue.withAlphaComponent(0.5)
        }
    }

    private var voiceIconName: String {
        guard hasFullAccess else { return "gearshape.fill" }
        switch currentBridgeStatus?.state {
        case .recording: return "stop.fill"
        case .sending: return "hourglass"
        default: return "mic.fill"
        }
    }

    /// Vertical gradient: top color slightly lighter than bottom for soft
    /// depth. Returned as `[UIColor]`; the layer converts to `CGColor`.
    private var voiceGradientColors: [UIColor] {
        let (top, bottom) = gradientStops
        return [top, bottom]
    }

    private var voiceShadowColor: UIColor {
        gradientStops.bottom
    }

    private var gradientStops: (top: UIColor, bottom: UIColor) {
        guard hasFullAccess else {
            return (
                UIColor(red: 1.00, green: 0.66, blue: 0.30, alpha: 1),
                UIColor(red: 0.95, green: 0.50, blue: 0.18, alpha: 1)
            )
        }
        if isOpeningHostApp {
            return (
                UIColor(red: 0.60, green: 0.50, blue: 0.96, alpha: 1),
                UIColor(red: 0.36, green: 0.28, blue: 0.80, alpha: 1)
            )
        }
        switch currentBridgeStatus?.state {
        case .recording:
            return (
                UIColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1),
                UIColor(red: 0.86, green: 0.18, blue: 0.20, alpha: 1)
            )
        case .sending:
            return (
                UIColor(red: 0.60, green: 0.50, blue: 0.96, alpha: 1),
                UIColor(red: 0.36, green: 0.28, blue: 0.80, alpha: 1)
            )
        case .error:
            if isBridgeAwake {
                return (
                    UIColor(red: 1.00, green: 0.66, blue: 0.30, alpha: 1),
                    UIColor(red: 0.95, green: 0.50, blue: 0.18, alpha: 1)
                )
            }
            fallthrough
        default:
            // Blue idle: noticeably brighter top → cooler/deeper bottom. Lifts
            // off the keyboard chrome instead of reading as a flat color block.
            return (
                UIColor(red: 0.34, green: 0.66, blue: 1.00, alpha: 1),
                UIColor(red: 0.10, green: 0.40, blue: 0.92, alpha: 1)
            )
        }
    }

    private var statusColor: UIColor {
        if !hasFullAccess { return .systemOrange }
        if isOpeningHostApp { return .systemBlue }
        guard isBridgeAwake else { return .systemGray3 }
        switch currentBridgeStatus?.state {
        case .standby, .result: return .systemGreen
        case .recording: return .systemRed
        case .sending: return .systemBlue
        case .error: return .systemOrange
        default: return .systemGray3
        }
    }

    private var statusText: String {
        if !hasFullAccess {
            return "Setup"
        }
        if isOpeningHostApp {
            return "Opening"
        }
        if !isBridgeAwake {
            return "Ready"
        }
        guard let status = currentBridgeStatus else {
            return "Ready"
        }
        switch status.state {
        case .standby:
            return "Ready"
        case .recording:
            return "Recording"
        case .sending:
            return "Sending"
        case .result:
            return "Inserted"
        case .error:
            return isBridgeAwake ? "Issue" : "Ready"
        case .idle:
            return "Ready"
        }
    }

    private func syncKeyboardSettingsToHost() {
        guard hasFullAccess, isBridgeAwake else { return }
        sendBridgeCommand(.configure)
    }

    private func sendBridgeCommand(_ action: KeyboardBridgeCommandAction) {
        let command = KeyboardBridgeCommand(
            action: action,
            correctionMode: correctionMode.rawValue
        )
        sendBridgeCommand(command)
    }

    private func sendBridgeCommand(_ command: KeyboardBridgeCommand) {
        let action = command.action
        if action != .configure {
            if action == .start, command.textEditContext != nil || command.dictationContext != nil {
                sendLocalBridgeCommand(command)
                return
            }
            if action == .stop {
                sendLocalBridgeCommand(command)
                return
            }
            sendDarwinBridgeCommand(action, commandID: command.id)
            return
        }

        sendLocalBridgeCommand(command)
    }

    private func sendLocalBridgeCommand(_ command: KeyboardBridgeCommand) {
        if command.action == .start || command.action == .stop {
            if command.action == .start, inputMode == .tap {
                tapRecordingActive = true
            }
            if command.action == .stop {
                tapRecordingActive = false
            }
            bridgeStatus = KeyboardBridgeStatus(
                commandID: command.id,
                state: command.action == .start ? .standby : .sending,
                message: command.action == .start ? "Starting recording" : "Sending"
            )
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.send(command, timeout: command.action.requestTimeout)
                await MainActor.run {
                    self.applyBridgeStatus(status)
                    if command.action == .start {
                        self.finishStartRequestIfNeeded(status: status)
                    }
                }
            } catch {
                await MainActor.run {
                    if command.action == .stop {
                        self.sendDarwinBridgeCommand(.stop, commandID: command.id)
                        return
                    }
                    if command.action == .start {
                        if command.textEditContext == nil {
                            self.sendDarwinBridgeCommand(.start, commandID: command.id)
                            return
                        }
                        self.isStartRequestInFlight = false
                        self.activeRecordingTextTarget = nil
                    }
                    self.bridgeStatus = KeyboardBridgeStatus(
                        commandID: command.id,
                        state: .error,
                        message: "Open Typeforme once to prepare dictation."
                    )
                    self.lastBridgeContactAt = 0
                    self.updateUI()
                }
            }
        }
    }

    private func sendDarwinBridgeCommand(_ action: KeyboardBridgeCommandAction, commandID: String) {
        if action == .start || action == .stop {
            if action == .start, inputMode == .tap {
                tapRecordingActive = true
            }
            if action == .stop {
                tapRecordingActive = false
            }
            bridgeStatus = KeyboardBridgeStatus(
                commandID: commandID,
                state: action == .start ? .standby : .sending,
                message: action == .start ? "Starting recording" : "Sending"
            )
            lastBridgeContactAt = Date().timeIntervalSince1970
            updateUI()
        }

        switch action {
        case .start:
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.requestStartDictation)
            scheduleHostOpenIfStartStalls()
        case .stop:
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.requestStopDictation)
        case .cancel:
            tapRecordingActive = false
            activeRecordingTextTarget = nil
            cancelScheduledHostOpen()
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.requestCancelDictation)
        case .configure, .restyleText:
            break
        }
    }

    private func finishStoppedNotification() {
        cancelScheduledHostOpen()
        guard isStartRequestInFlight else { return }
        isStartRequestInFlight = false
        shouldStopWhenStartCompletes = false
        shouldCancelWhenStartCompletes = false
        isVoicePressActive = false
        isCommandPressActive = false
        tapRecordingActive = false
    }

    private func scheduleHostOpenIfStartStalls() {
        cancelScheduledHostOpen()
        scheduledHostOpenTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.isStartRequestInFlight,
                      self.currentBridgeStatus?.state != .recording,
                      !self.isOpeningHostApp
                else { return }
                self.isStartRequestInFlight = false
                self.openHostForDictation()
            }
        }
    }

    private func cancelScheduledHostOpen() {
        scheduledHostOpenTask?.cancel()
        scheduledHostOpenTask = nil
    }

    private func startStatusPolling(interval: TimeInterval = 0.35) {
        guard statusTimer == nil else { return }
        statusTimerInterval = interval
        statusTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshBridgeStatus()
        }
        if let statusTimer {
            RunLoop.current.add(statusTimer, forMode: .common)
        }
    }

    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
        statusTimerInterval = 0
    }

    private func scheduleDeferredStartupProbe() {
        deferredStartupWorkItem?.cancel()
        hasPresentedInitialFrame = false
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.startStatusPolling()
            self.refreshBridgeStatus(captureSelection: false)
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.requestSessionStatus)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self, self.view.window != nil else { return }
                self.hasPresentedInitialFrame = true
            }
        }
        deferredStartupWorkItem = workItem

        // Let iOS draw the first keyboard frame before touching localhost,
        // Darwin notifications, or textDocumentProxy selection APIs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func refreshBridgeStatus(captureSelection: Bool = true) {
        if captureSelection {
            refreshSelectionSnapshot()
        }
        guard hasFullAccess else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await localClient.status()
                await MainActor.run {
                    self.applyBridgeStatus(status)
                }
            } catch {
                await MainActor.run {
                    self.lastBridgeContactAt = 0
                    self.updateUI()
                }
            }
        }
    }

    private func applyBridgeStatus(_ status: KeyboardBridgeStatus) {
        if isStartRequestInFlight && status.state == .standby {
            return
        }
        if status.state != .idle {
            openingHostUntil = 0
        }
        if status.state == .recording, inputMode == .tap {
            tapRecordingActive = true
        } else if status.state != .recording && status.state != .sending {
            tapRecordingActive = false
        }
        bridgeStatus = status
        lastBridgeContactAt = Date().timeIntervalSince1970
        if !hasUserSelectedCorrectionMode,
           let rawDefault = status.defaultCorrectionMode,
           let defaultMode = CorrectionModePreset(rawValue: rawDefault),
           defaultMode != correctionMode {
            correctionMode = defaultMode
            lastCorrectionModeButtonSignature = ""
        }
        if status.state == .result,
           status.commandID != styleRewriteCommandID,
           let commandID = status.commandID,
           defaults.string(forKey: lastInsertedCommandIDKey) != commandID,
           let text = status.resultText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            if hasFullAccess {
                UIPasteboard.general.string = text
            }
            let didApply: Bool
            if let target = activeRecordingTextTarget {
                didApply = applyRewrittenText(text, replacing: target)
                activeRecordingTextTarget = nil
            } else {
                textDocumentProxy.insertText(text)
                didApply = true
            }
            if didApply {
                defaults.set(commandID, forKey: lastInsertedCommandIDKey)
                defaults.set(text, forKey: lastInsertedTextKey)
                recentSelectionTarget = nil
            } else {
                bridgeStatus = KeyboardBridgeStatus(commandID: commandID, state: .error, message: "Selection changed; result copied.")
            }
        }

        if status.state == .error || status.state == .idle {
            activeRecordingTextTarget = nil
            recentSelectionTarget = nil
        }

        if status.state == .recording {
            voicePrint.level = status.audioLevel ?? 0
        }

        let signature = [
            status.commandID ?? "",
            status.state.rawValue,
            String(Int(status.updatedAt)),
            status.message,
            status.defaultCorrectionMode ?? "",
            status.audioDurationSeconds.map { String(format: "%.2f", $0) } ?? "",
            status.rawTranscriptLength.map(String.init) ?? "",
        ].joined(separator: ":")
        guard signature != lastStatusSignature else { return }
        lastStatusSignature = signature
        updateUI(animated: hasPresentedInitialFrame)
    }
}

// MARK: - Voice Controls

private final class VoiceOrbButton: UIButton {
    private let hitOutset: CGFloat = 10

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.insetBy(dx: -hitOutset, dy: -hitOutset).contains(point)
    }
}

/// Vertical-bars voiceprint rendered with a `CADisplayLink`. `level` is the
/// most recent normalized RMS sample (0...1) from the host's microphone
/// metering — set it on each status poll. The view smooths between samples and
/// mixes two phase-shifted sines per bar so the motion stays organic even
/// during silence.
private final class VoicePrintView: UIView {
    var level: Float = 0 {
        didSet {
            targetLevel = max(0, min(1, level))
            lastLevelUpdateAt = CACurrentMediaTime()
            if isIdleBarAnimationActive {
                stopBarAnimations()
            }
        }
    }

    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? start() : stop()
        }
    }

    var tint: UIColor = .white {
        didSet { barLayers.forEach { $0.backgroundColor = tint.cgColor } }
    }

    private let barCount = 9
    private var barLayers: [CALayer] = []
    private var displayLink: CADisplayLink?
    private var phase: CFTimeInterval = 0
    private var smoothedLevel: Float = 0
    private var targetLevel: Float = 0
    private var lastLevelUpdateAt: CFTimeInterval = 0
    private var isIdleBarAnimationActive = false

    private let staleLevelInterval: CFTimeInterval = 0.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        setupBars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        displayLink?.invalidate()
    }

    private func setupBars() {
        for _ in 0..<barCount {
            let layer = CALayer()
            layer.backgroundColor = tint.cgColor
            layer.cornerRadius = 2.5
            layer.cornerCurve = .continuous
            self.layer.addSublayer(layer)
            barLayers.append(layer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars()
    }

    private func layoutBars() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        let barW: CGFloat = 5
        let totalBars = CGFloat(barCount)
        let gap = (w - totalBars * barW) / (totalBars + 1)
        let centerY = h / 2
        let baseHeight = max(8, h * 0.18)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, layer) in barLayers.enumerated() {
            let x = gap + CGFloat(i) * (barW + gap)
            layer.frame = CGRect(x: x, y: centerY - baseHeight / 2, width: barW, height: baseHeight)
        }
        CATransaction.commit()
    }

    private func start() {
        guard displayLink == nil else { return }
        lastLevelUpdateAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        stopBarAnimations()
        smoothedLevel = 0
        targetLevel = 0
        lastLevelUpdateAt = 0
        layoutBars()
    }

    private func startBarAnimations() {
        guard !isIdleBarAnimationActive else { return }
        isIdleBarAnimationActive = true
        let now = CACurrentMediaTime()
        for (i, layer) in barLayers.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = [0.70, 1.25, 0.82, 1.42, 0.74]
            animation.keyTimes = [0, 0.28, 0.52, 0.78, 1]
            animation.duration = 0.86 + Double(i % 3) * 0.08
            animation.beginTime = now + Double(i) * 0.045
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            layer.add(animation, forKey: "voiceprint.breathe")
        }
    }

    private func stopBarAnimations() {
        guard isIdleBarAnimationActive else { return }
        isIdleBarAnimationActive = false
        for layer in barLayers {
            layer.removeAnimation(forKey: "voiceprint.breathe")
            layer.transform = CATransform3DIdentity
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        phase += link.duration
        updateIdleBarAnimationIfNeeded(now: CACurrentMediaTime())
        let rate: Float = targetLevel > smoothedLevel ? 0.45 : 0.12
        smoothedLevel += (targetLevel - smoothedLevel) * rate

        let h = bounds.height
        guard h > 0, bounds.width > 0 else { return }
        let centerY = h / 2
        let minH = max(6, h * 0.12)
        let maxH = h * 0.95
        // Baseline 0.30 + voiceBoost (level * 2.2): bars breathe visibly at
        // silence, span the full range when speech hits. Old `0.08 * (0.45+
        // 0.55*wave)` formula collapsed everything into the bottom 8% of the
        // view height — looked frozen.
        let baseline: CGFloat = 0.30
        let voiceBoost = CGFloat(smoothedLevel) * 2.2
        let envelope = min(1.0, baseline + voiceBoost)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, layer) in barLayers.enumerated() {
            let bias = abs(Double(i) - Double(barCount - 1) / 2.0) / (Double(barCount - 1) / 2.0)
            let centerBoost = 1.0 - bias * 0.30
            let bandPhase = Double(i) * 0.55
            let s = sin(phase * 5.4 + bandPhase) * 0.55 + sin(phase * 11.1 + bandPhase * 2.3) * 0.45
            let waveform = CGFloat((s + 1) / 2)
            let modulation = envelope * CGFloat(centerBoost) * (0.35 + 0.65 * waveform)
            let barH = max(minH, min(maxH, minH + (maxH - minH) * modulation))
            var frame = layer.frame
            frame.origin.y = centerY - barH / 2
            frame.size.height = barH
            layer.frame = frame
        }
        CATransaction.commit()
    }

    private func updateIdleBarAnimationIfNeeded(now: CFTimeInterval) {
        guard isActive, lastLevelUpdateAt > 0 else {
            stopBarAnimations()
            return
        }
        if now - lastLevelUpdateAt > staleLevelInterval {
            startBarAnimations()
        } else {
            stopBarAnimations()
        }
    }
}

private final class VoiceInputModeSwitch: UIControl {
    var onSelection: ((String) -> Void)?

    var mode: String = "hold" {
        didSet {
            guard mode != oldValue else { return }
            updateAppearance(animated: true)
        }
    }

    private let trackView = UIView()
    private let thumbView = UIView()
    private let holdButton = UIButton(type: .system)
    private let tapButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var isHighlighted: Bool {
        didSet {
            updateHighlight()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 68, height: 82)
    }

    private func configure() {
        isAccessibilityElement = true
        accessibilityTraits = .button

        trackView.isUserInteractionEnabled = false
        trackView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        trackView.layer.borderWidth = 0.5
        trackView.layer.borderColor = UIColor.separator.cgColor
        trackView.layer.shadowColor = UIColor.black.cgColor
        trackView.layer.shadowOpacity = 0.10
        trackView.layer.shadowRadius = 8
        trackView.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(trackView)

        thumbView.isUserInteractionEnabled = false
        thumbView.backgroundColor = .label
        addSubview(thumbView)

        configureButton(holdButton, title: "Hold", action: #selector(selectHold))
        configureButton(tapButton, title: "Tap", action: #selector(selectTap))
        addSubview(holdButton)
        addSubview(tapButton)
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 11, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.addTarget(self, action: action, for: .primaryActionTriggered)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75
        button.accessibilityLabel = title
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackView.frame = bounds
        trackView.layer.cornerRadius = bounds.width / 2
        trackView.layer.cornerCurve = .continuous

        let inset: CGFloat = 4
        let segmentHeight = (bounds.height - inset * 2) / 2
        let thumbY = mode == "tap" ? inset + segmentHeight : inset
        thumbView.frame = CGRect(
            x: inset,
            y: thumbY,
            width: bounds.width - inset * 2,
            height: segmentHeight
        )
        thumbView.layer.cornerRadius = min(thumbView.bounds.width, thumbView.bounds.height) / 2
        thumbView.layer.cornerCurve = .continuous

        holdButton.frame = CGRect(x: 6, y: inset, width: bounds.width - 12, height: segmentHeight)
        tapButton.frame = CGRect(x: 6, y: inset + segmentHeight, width: bounds.width - 12, height: segmentHeight)
        applyColors()
    }

    private func updateAppearance(animated: Bool) {
        let apply = {
            self.applyColors()
            self.accessibilityValue = self.mode == "tap" ? "Tap" : "Hold"
            self.setNeedsLayout()
        }
        if animated, window != nil {
            apply()
            UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.layoutIfNeeded()
            }
        } else {
            apply()
        }
    }

    private func applyColors() {
        holdButton.configuration?.baseForegroundColor = mode == "hold" ? .systemBackground : .secondaryLabel
        tapButton.configuration?.baseForegroundColor = mode == "tap" ? .systemBackground : .secondaryLabel
        holdButton.isUserInteractionEnabled = isEnabled
        tapButton.isUserInteractionEnabled = isEnabled
    }

    func refreshAppearance(style: UIUserInterfaceStyle) {
        overrideUserInterfaceStyle = style
        trackView.overrideUserInterfaceStyle = style
        thumbView.overrideUserInterfaceStyle = style
        holdButton.overrideUserInterfaceStyle = style
        tapButton.overrideUserInterfaceStyle = style
        trackView.backgroundColor = UIColor.secondarySystemBackground
            .withAlphaComponent(style == .dark ? 0.30 : 0.72)
        thumbView.backgroundColor = .label
        trackView.layer.borderColor = UIColor.separator
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .cgColor
        holdButton.setNeedsUpdateConfiguration()
        tapButton.setNeedsUpdateConfiguration()
        applyColors()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        holdButton.isEnabled = enabled
        tapButton.isEnabled = enabled
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = enabled ? 1 : 0.45
        }
        updateAppearance(animated: false)
    }

    private func updateHighlight() {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
        }
    }

    @objc private func selectHold() {
        onSelection?("hold")
    }

    @objc private func selectTap() {
        onSelection?("tap")
    }
}
