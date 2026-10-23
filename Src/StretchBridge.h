#ifndef STRETCH_BRIDGE_H
#define STRETCH_BRIDGE_H
#ifdef __cplusplus
extern "C" {
#endif

// Rend hors-ligne un signal planaire (inputs[c][i]) avec time-stretch + pitch de haute qualité
// (Signalsmith Stretch). stretchRatio = longueur_sortie / longueur_entrée
//   (0.5 = deux fois plus rapide, 2.0 = deux fois plus lent).
// semitones = transposition (indépendante de la vitesse).
// Écrit jusqu'à outCapacity frames dans outBuffers[c], renvoie le nombre réel dans *outFrames.
// Retour 0 si OK.
int sl_render(const float* const* inputs, int channels, int inFrames,
              double sampleRate, double stretchRatio, float semitones,
              float* const* outBuffers, int outCapacity, int* outFrames);

#ifdef __cplusplus
}
#endif
#endif
