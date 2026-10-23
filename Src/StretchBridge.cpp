#include "StretchBridge.h"
#include "signalsmith-stretch.h"
#include <vector>
#include <algorithm>
#include <cmath>

int sl_render(const float* const* inputs, int channels, int inFrames,
              double sampleRate, double stretchRatio, float semitones,
              float* const* outBuffers, int outCapacity, int* outFrames) {
    if (channels <= 0 || inFrames <= 0 || outCapacity <= 0) { if (outFrames) *outFrames = 0; return 1; }

    signalsmith::stretch::SignalsmithStretch<float> st;
    st.presetDefault(channels, (float)sampleRate);
    st.setTransposeSemitones(semitones);
    st.reset();

    const int inLat  = st.inputLatency();
    const int outLat = st.outputLatency();

    int outSamples = (int)std::lround((double)inFrames * stretchRatio);
    if (outSamples < 1) outSamples = 1;
    if (outSamples > outCapacity) outSamples = outCapacity;

    const int inTotal  = inFrames + inLat;      // zéros en fin pour vider la latence
    const int outTotal = outSamples + outLat;   // marge pour jeter l'amorçage

    std::vector<std::vector<float>> pin(channels, std::vector<float>(inTotal, 0.0f));
    std::vector<float*> pinPtr(channels);
    for (int c = 0; c < channels; ++c) {
        std::copy(inputs[c], inputs[c] + inFrames, pin[c].begin());
        pinPtr[c] = pin[c].data();
    }

    std::vector<std::vector<float>> pout(channels, std::vector<float>(outTotal, 0.0f));
    std::vector<float*> poutPtr(channels);
    for (int c = 0; c < channels; ++c) poutPtr[c] = pout[c].data();

    st.process(pinPtr.data(), inTotal, poutPtr.data(), outTotal);

    for (int c = 0; c < channels; ++c)
        std::copy(pout[c].begin() + outLat, pout[c].begin() + outLat + outSamples, outBuffers[c]);

    if (outFrames) *outFrames = outSamples;
    return 0;
}
