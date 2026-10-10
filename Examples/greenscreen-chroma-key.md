# Green screen video chroma key

From the repository root, open the example in the Pipeline Editor:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift run PixeltjePipeline Examples/greenscreen-chroma-key.pixpipeline.json
```

The editor looks for `greenscreen.mp4` beside the workflow. In this checkout,
an ignored local link points there from `Examples` to `~/Downloads/greenscreen.mp4`,
so the workflow can run as soon as it opens. In another checkout, click
**Replace Video…** on **Green screen source** and choose the clip, or use
**Choose Source Media Folder…** in the execution inspector to select its folder.

**Video Preview** plays the source and sends the frame selected by Loop's
`callIndex` to its `image` output. The example scales that frame to 540 × 960,
marks pixels whose green channel exceeds both red and blue by 0.18, softens
the edge, and places the remaining subject over a generated aurora background.
**Processed frame preview** shows the latest composite. **Video Output** writes
the 1,070 frames to one 60 fps H.264 MP4 when the Loop finishes. The example
does not copy the source audio into the rendered video.
For a quick visual check, set Loop's **Max calls** to 2 or 10 before running;
restore 1,070 for the entire clip. This model-free raster workflow processes
frames sequentially and can take much longer than the video's playback time.

The **Green excess threshold** exposed control can be adjusted before a run.
Larger values retain more of the original green screen; smaller values remove
more of it. For another clip, choose its file and set Loop's **Max calls** to
its frame count. The Video Preview player is for viewing; Loop controls which
frame is sent through the processing graph.
