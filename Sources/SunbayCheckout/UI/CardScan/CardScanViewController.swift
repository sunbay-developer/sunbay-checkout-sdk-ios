#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import AVFoundation
    import UIKit
    import Vision

    /// Gathers the device facts for `CardScanSupport` (camera, permission, Info.plist key).
    enum CardScanAvailability {
        /// Whether to offer scanning for the given host policy. Reads only system state; no card data.
        static func isAvailable(policy: Appearance.CardScanning) -> Bool {
            let usage = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
            let access: CardScanSupport.CameraAccess
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined: access = .notDetermined
            case .authorized: access = .authorized
            case .denied: access = .denied
            case .restricted: access = .restricted
            @unknown default: access = .denied
            }
            return CardScanSupport.isAvailable(
                hostAllows: policy != .disabled,
                hasUsageDescription: !(usage ?? "").isEmpty,
                hasCamera: AVCaptureDevice.default(for: .video) != nil,
                access: access
            )
        }
    }

    /// Full-screen, fully on-device card scanner: AVFoundation capture + Vision text recognition.
    ///
    /// Frames are processed in memory and dropped; nothing is stored, logged, or sent anywhere. The
    /// session stops at the first stable result (see `CardScanStabilizer`) or when cancelled.
    final class CardScanViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
        /// Called once on the main queue with a stable result. The scanner dismisses itself afterwards.
        var onScanned: ((ScannedCard) -> Void)?

        private let appearance: ResolvedAppearance
        private let localize: (String) -> String

        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.sunbay.checkout.cardscan.session")
        private let videoQueue = DispatchQueue(label: "com.sunbay.checkout.cardscan.video")
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private let guideView = UIView()
        private let hintLabel = UILabel()
        private let liveLabel = UILabel()
        private let cancelButton = UIButton(type: .system)
        private let torchButton = UIButton(type: .system)
        private var captureDevice: AVCaptureDevice?
        private var tipWorkItem: DispatchWorkItem?

        /// How long to scan without a result before suggesting a different angle / the light.
        private static let tipDelay: TimeInterval = 6

        // Touched only on `videoQueue`.
        private var stabilizer = CardScanStabilizer()
        private var voter = CardScanDigitVoter()
        private var isRecognizing = false
        private var finished = false
        // Region-of-interest inputs, written on `videoQueue` from the main thread's layout.
        private var roiGuide: CGRect = .zero
        private var roiViewSize: CGSize = .zero

        init(appearance: ResolvedAppearance, localize: @escaping (String) -> String) {
            self.appearance = appearance
            self.localize = localize
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .overFullScreen  // keeps the sheet's view in place (no remove/restore glitch)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var prefersStatusBarHidden: Bool { true }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configureOverlay()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            startWhenAuthorized()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            tipWorkItem?.cancel()
            setTorch(false)
            stopSession()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
            let guide = guideView.frame
            let size = view.bounds.size
            videoQueue.async { [weak self] in
                self?.roiGuide = guide
                self?.roiViewSize = size
            }
        }

        // MARK: - Overlay

        private func configureOverlay() {
            guideView.layer.borderColor = appearance.primary.cgColor
            guideView.layer.borderWidth = 3
            guideView.layer.cornerRadius = 14
            guideView.translatesAutoresizingMaskIntoConstraints = false
            guideView.isUserInteractionEnabled = false

            hintLabel.text = localize("sunbay.card.scan.hint")
            hintLabel.textColor = .white
            hintLabel.font = .preferredFont(forTextStyle: .subheadline)
            hintLabel.textAlignment = .center
            hintLabel.numberOfLines = 0
            hintLabel.translatesAutoresizingMaskIntoConstraints = false

            cancelButton.setTitle(localize("sunbay.sheet.cancel"), for: .normal)
            cancelButton.setTitleColor(.white, for: .normal)
            cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
            cancelButton.translatesAutoresizingMaskIntoConstraints = false
            cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

            torchButton.setImage(
                UIImage(
                    systemName: "bolt.slash.fill",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)),
                for: .normal)
            torchButton.tintColor = .white
            torchButton.isHidden = true  // shown once we know the device has a torch
            torchButton.accessibilityLabel = localize("sunbay.card.scan.light")
            torchButton.translatesAutoresizingMaskIntoConstraints = false
            torchButton.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)

            view.addSubview(guideView)
            view.addSubview(hintLabel)
            view.addSubview(cancelButton)
            view.addSubview(torchButton)

            liveLabel.textColor = appearance.primary
            liveLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
            liveLabel.textAlignment = .center
            liveLabel.adjustsFontSizeToFitWidth = true
            liveLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(liveLabel)
            NSLayoutConstraint.activate([
                liveLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 12),
                liveLabel.leadingAnchor.constraint(equalTo: guideView.leadingAnchor),
                liveLabel.trailingAnchor.constraint(equalTo: guideView.trailingAnchor),
            ])

            // ISO/IEC 7810 ID-1 card ratio: 85.60 × 53.98 mm.
            NSLayoutConstraint.activate([
                guideView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                guideView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                guideView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                guideView.heightAnchor.constraint(equalTo: guideView.widthAnchor, multiplier: 53.98 / 85.60),
                hintLabel.topAnchor.constraint(equalTo: guideView.bottomAnchor, constant: 20),
                hintLabel.leadingAnchor.constraint(equalTo: guideView.leadingAnchor),
                hintLabel.trailingAnchor.constraint(equalTo: guideView.trailingAnchor),
                cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                torchButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
                torchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                torchButton.widthAnchor.constraint(equalToConstant: 44),
                torchButton.heightAnchor.constraint(equalToConstant: 44),
            ])
        }

        @objc private func cancelTapped() {
            dismiss(animated: true)
        }

        @objc private func torchTapped() {
            setTorch(captureDevice?.torchMode != .on)
        }

        /// Turns the torch on/off (embossed digits read better with raking light).
        private func setTorch(_ on: Bool) {
            guard let device = captureDevice, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            let name = on ? "bolt.fill" : "bolt.slash.fill"
            torchButton.setImage(
                UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)),
                for: .normal)
            torchButton.tintColor = on ? appearance.primary : .white
        }

        /// If nothing was scanned for a while, suggest what usually helps (angle, steadiness, light).
        private func scheduleTip() {
            tipWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hintLabel.text = self.localize("sunbay.card.scan.tip")
            }
            tipWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tipDelay, execute: work)
        }

        // MARK: - Capture

        private func startWhenAuthorized() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted { self?.configureAndStart() } else { self?.dismiss(animated: true) }
                    }
                }
            default:
                dismiss(animated: true)
            }
        }

        private func configureAndStart() {
            guard previewLayer == nil,
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: device)
            else {
                dismiss(animated: true)
                return
            }
            captureDevice = device
            torchButton.isHidden = !device.hasTorch
            scheduleTip()
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)

            sessionQueue.async { [session] in
                session.beginConfiguration()
                session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .hd1280x720
                // Close-range, continuous focus: small embossed digits need to be sharp.
                if (try? device.lockForConfiguration()) != nil {
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
                    device.unlockForConfiguration()
                }
                if session.canAddInput(input) { session.addInput(input) }
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
                session.startRunning()
            }
        }

        private func stopSession() {
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        // MARK: - Recognition

        func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard !finished, !isRecognizing, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            isRecognizing = true
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false  // digits: dictionary "corrections" only hurt.
            request.minimumTextHeight = 0.01  // allow small embossed digits (default ignores tiny text)
            // Only look inside the guide area (plus margin). The upright image is the buffer rotated 90°.
            let uprightSize = CGSize(
                width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer))
            request.regionOfInterest = CardScanROI.normalizedRegion(
                guide: roiGuide, viewSize: roiViewSize, imageSize: uprightSize)
            // Back camera in portrait delivers landscape-right buffers.
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
            try? handler.perform([request])

            let lines = Self.readingOrderLines(from: request.results ?? [])
            DispatchQueue.main.async { [weak self] in self?.showLiveFeedback(lines: lines) }
            let voted = voter.ingest(lines: lines)  // one vote per frame
            var candidate = CardScanParser.parse(lines: lines)
            if candidate == nil, let voted {
                let expiry = CardScanParser.extractExpiry(from: lines, now: Date())
                candidate = ScannedCard(pan: voted, expiryMonth: expiry?.month, expiryYear: expiry?.year)
            }
            if let card = stabilizer.ingest(candidate, at: timestamp) {
                finished = true
                DispatchQueue.main.async { [weak self] in self?.complete(with: card) }
            }
            isRecognizing = false
        }

        /// Groups recognized observations into rows (top to bottom) and joins each row left to right.
        /// Vision does not guarantee result order, and digit groups can arrive as separate observations.
        private static func readingOrderLines(from observations: [VNRecognizedTextObservation]) -> [String] {
            let items = observations.compactMap { obs -> (box: CGRect, text: String)? in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                return (obs.boundingBox, text)
            }
            // Vision's origin is bottom-left, so a larger midY is higher on the card.
            let sorted = items.sorted { $0.box.midY > $1.box.midY }
            var rows: [[(box: CGRect, text: String)]] = []
            for item in sorted {
                if let last = rows.last?.first, abs(last.box.midY - item.box.midY) < 0.06 {
                    rows[rows.count - 1].append(item)
                } else {
                    rows.append([item])
                }
            }
            var lines = items.map(\.text)  // each observation on its own too (covers un-split numbers)
            lines += rows.filter { $0.count > 1 }.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            return lines
        }

        /// Shows the digits currently being read so the user can see the scanner is working and adjust
        /// distance/angle. On-screen only (the user's own card on their own device); never logged.
        private func showLiveFeedback(lines: [String]) {
            let best = lines.map(CardScanParser.normalizeDigitLookalikes)
                .compactMap { line -> String? in
                    let digits = line.filter(\.isNumber)
                    return digits.count >= 8 ? CardFormView.formatPAN(String(digits)) : nil
                }
                .max { $0.count < $1.count }
            liveLabel.text = best
        }

        private func complete(with card: ScannedCard) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            stopSession()
            dismiss(animated: true) { [onScanned] in onScanned?(card) }
        }
    }
#endif
