import PixeltjePipelineResourceLinking
import Testing

@Test func fixedStableAudioExportKeepsItsTracedWindow() throws {
  let window = try #require(StableAudio3LatentWindow(metadata: [
    "latent_frames": 88, "duration_seconds": 2, "padding_seconds": 6,
  ]))
  #expect(!window.isDynamic)
  #expect(window.maxDurationSeconds == 2)
  #expect(window.frames(forDuration: 0.25) == 88)
  #expect(window.frames(forDuration: 2) == 88)
}

@Test func dynamicStableAudioExportSizesWindowLikeThePublisher() throws {
  let window = try #require(StableAudio3LatentWindow(metadata: [
    "latent_frames": 184, "min_latent_frames": 68, "latent_frame_alignment": 2,
    "downsampling_ratio": 4_096, "duration_seconds": 11, "padding_seconds": 6,
  ]))
  #expect(window.isDynamic)
  #expect(window.maxDurationSeconds == 11)
  #expect(window.frames(forDuration: 0.25) == 68)
  #expect(window.frames(forDuration: 2) == 88)
  #expect(window.frames(forDuration: 8) == 152)
  #expect(window.frames(forDuration: 11) == 184)
}

@Test func stableAudioWindowRejectsInconsistentMetadata() {
  // An 8-second clip plus headroom needs 152 frames, more than this window.
  #expect(StableAudio3LatentWindow(metadata: [
    "latent_frames": 88, "min_latent_frames": 68, "latent_frame_alignment": 2,
    "duration_seconds": 8, "padding_seconds": 6,
  ]) == nil)
  #expect(StableAudio3LatentWindow(metadata: [
    "latent_frames": 184, "min_latent_frames": 67, "latent_frame_alignment": 2,
    "duration_seconds": 11, "padding_seconds": 6,
  ]) == nil)
  #expect(StableAudio3LatentWindow(metadata: [
    "latent_frames": 88, "duration_seconds": 2, "padding_seconds": 6,
    "downsampling_ratio": 2_048,
  ]) == nil)
}
