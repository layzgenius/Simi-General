// ValenceArousalPredictor.swift
// Simi — Music Discovery App
//
// On-device DEAM valence + arousal regressor backed by two CoreML GBM models.
// Both models are loaded once at first access. Returns nil on any failure so
// LocalAudioAnalyzer always falls back to the DSP proxy.

import CoreML
import Foundation

/// Singleton that wraps two CoreML regressors (valence + arousal) trained on DEAM.
///
/// Usage:
/// ```swift
/// let result = ValenceArousalPredictor.shared.predict(features: featureVector)
/// ```
/// Returns nil when the `.mlpackage` bundles are absent (models not yet trained/added)
/// or when `features.count != 58`.
final class ValenceArousalPredictor {

    static let shared = ValenceArousalPredictor()

    private static let nFeatures = 58

    private let valenceModel: MLModel?
    private let arousalModel: MLModel?

    private init() {
        func load(_ name: String) -> MLModel? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: name, withExtension: "mlpackage")
            else { return nil }
            return try? MLModel(contentsOf: url)
        }
        valenceModel = load("SimiValenceRegressor")
        arousalModel = load("SimiArousalRegressor")
    }

    /// Predict valence and arousal from a 58-element SonicDNA feature vector.
    ///
    /// Feature order must match `build_feature_vector()` in extract_features.py:
    ///   [0:20]  mfccMean       L2-normalized, 20 coefficients
    ///   [20:40] mfccStd        L2-normalized, 20 coefficients
    ///   [40:52] chroma         12-bin chroma, sum-normalized
    ///   [52]    chromaEntropy
    ///   [53]    mode           0 = minor, 1 = major
    ///   [54]    modeConf
    ///   [55]    energy
    ///   [56]    spectralWarmth
    ///   [57]    tonalClarity
    ///
    /// - Parameter features: 58-element Double vector in the order above.
    /// - Returns: `(valence, arousal)` both clamped to [0, 1], or nil on failure.
    func predict(features: [Double]) -> (valence: Double, arousal: Double)? {
        guard features.count == Self.nFeatures,
              let vm = valenceModel,
              let am = arousalModel
        else { return nil }

        guard let array = try? MLMultiArray(shape: [NSNumber(value: Self.nFeatures)],
                                            dataType: .double)
        else { return nil }
        for (i, v) in features.enumerated() { array[i] = NSNumber(value: v) }

        let dict: [String: Any] = ["features": MLFeatureValue(multiArray: array)]
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: dict),
              let vResult  = try? vm.prediction(from: provider),
              let aResult  = try? am.prediction(from: provider),
              let vVal     = vResult.featureValue(for: "valence")?.doubleValue,
              let aVal     = aResult.featureValue(for: "arousal")?.doubleValue
        else { return nil }

        return (valence: max(0, min(1, vVal)), arousal: max(0, min(1, aVal)))
    }
}
