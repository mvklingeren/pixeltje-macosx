# ComfyUI workflow download scripts

Pixeltje runs its bundled workflows on a separately installed, user-managed
ComfyUI server. Bundled workflows whose publishers permit unauthenticated
downloads have a Bash `.command` script that checks the model files they need,
then uses `curl` to download any missing files into a local ComfyUI `models`
directory after you confirm. Pixeltje does not manage the server or install
ComfyUI. The FLUX.2 Klein 9B Base and Distilled checkpoints are gated and must
be installed manually after accepting their publisher's model agreement.

Run a script from Terminal, for example:

```sh
./Scripts/ComfyUI/flux2-klein-inpaint-base.command --models-dir "/path/to/ComfyUI/models"
```

Or open a `.command` script in Terminal. It proposes
`~/ComfyUI-Shared/models`; press Return to accept that default or answer no to
enter another directory. Pass `--check` to inspect files without downloading,
or `--list` to see the required files and publisher pages without choosing a
directory. You can pass either the `models` directory or a ComfyUI directory
containing it. The assembled app includes these scripts under
`Contents/Resources/ComfyUISetup`.

The script reports missing files and compares installed files with the
publisher's SHA-256 where available. Downloads can resume from a partial file,
and verified files are moved into place only after the transfer completes. A
different hash may mean a different model revision; the script never replaces
an existing model. The `4x-ESRGAN.pth` listing has no published checksum in this
catalog, so the script reports that limitation. Afterward, rescan or restart
ComfyUI and check that the server offers the required nodes and models.

When the app detects a missing bundled model on a local ComfyUI server, it
shows the missing filenames and sizes and offers to open that workflow's script
in Terminal. The script proposes the shared default directory, lets you choose
another, and confirms the transfer. For a remote server or a custom model selection, use
that server's own setup process. These scripts cannot determine whether the
server version supports every node or whether the machine has enough memory
to run a workflow.

The two TSV files in `Sources/PixeltjeMacKit/Resources/ComfyUI` record each
template's model paths, sizes, direct download URLs, reference checksums, and
publisher pages. Keep them in sync with the bundled API workflow JSON when
editing a template.
