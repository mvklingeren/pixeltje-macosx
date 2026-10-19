// Spatial sound for Signal Range's looping voices.
// Included by SignalRangeFPSProgram.metal. A voice is four floats in the
// audio buffer that the engine reads after every frame: gain, playback rate,
// stereo pan, and one unused. The editor loops the voice's sound and applies
// them, so a moving source carries distance loss, panning and Doppler shift
// without any per-sample work here. Playback rate scales pitch and tempo
// together, as a real Doppler shift does.

// Real sound at drone speeds shifts pitch by only a few percent. A slower
// game-scale speed of sound keeps the rise and drop of a passing drone
// audible while the shift still follows the Doppler formula.
constant float dopplerSoundSpeed = 140.0f;
// Beyond this range a voice fades out completely.
constant float dopplerAudibleRange = 160.0f;

struct DopplerListener {
    float3 position;
    float3 velocity;
    float3 right;           // unit vector toward the right ear
};

struct DopplerSource {
    float3 position;
    float3 velocity;
    float loudness;         // gain at the reference distance
    float reference;        // metres within which the level stops rising
    float pitch;            // playback rate at rest, before the Doppler shift
};

// Gain, playback rate and pan of one source as the listener hears it.
float4 dopplerVoice(DopplerListener listener, DopplerSource source) {
    float3 offset = source.position - listener.position;
    float distance = length(offset);
    float3 direction = distance > 1.0e-3f ? offset / distance
        : float3(0.0f, 0.0f, -1.0f);
    // Speeds along the line of sight. Approach is the listener moving
    // toward the source; recession is the source moving away from the
    // listener. Both stay well below the speed of sound.
    float limit = 0.8f * dopplerSoundSpeed;
    float approach = clamp(dot(listener.velocity, direction), -limit, limit);
    float recession = clamp(dot(source.velocity, direction), -limit, limit);
    float shift = (dopplerSoundSpeed + approach)
        / (dopplerSoundSpeed + recession);
    // Inverse-distance loss of a point source, faded out at the edge of
    // hearing so a far voice ends silently rather than at a fixed floor.
    float gain = source.loudness * source.reference
        / max(distance, source.reference)
        * (1.0f - smoothstep(0.55f * dopplerAudibleRange,
            dopplerAudibleRange, distance));
    // Constant-sum panning keeps some of the source in both ears.
    float pan = 0.8f * dot(direction, listener.right);
    return float4(saturate(gain), clamp(source.pitch * shift, 0.25f, 4.0f),
        clamp(pan, -1.0f, 1.0f), 0.0f);
}

// Voices update at the game rate, about 30 Hz. Easing toward each new value
// keeps those steps from being heard as zipper noise. A voice coming out of
// silence takes its pitch and position at once instead of sliding into them.
float4 smoothVoice(float4 previous, float4 target, float dt) {
    if (previous.x <= 0.001f || previous.y <= 0.0f)
        previous = float4(previous.x, target.yzw);
    return mix(previous, target, 1.0f - exp(-dt * 10.0f));
}
