import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

import dictate


class DictationTests(unittest.TestCase):
    def test_wav_upload_and_transcript(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "clip.wav"
            with wave.open(str(path), "wb") as out:
                out.setparams((1, 2, 16000, 0, "NONE", ""))
                out.writeframes(b"\0\1" * 400)
            audio = dictate.read_audio(path)
            path.write_bytes(audio[:-1])
            with self.assertRaisesRegex(ValueError, "incomplete"):
                dictate.read_audio(path)

        choice = {"message": {"content": json.dumps({"transcript": "你好", "language": "zh"})}}
        response = io.BytesIO(json.dumps({"choices": [choice]}).encode())
        with patch("urllib.request.urlopen", return_value=response) as send:
            self.assertEqual(dictate.transcribe(audio, "test", "example"), "你好")
        request = send.call_args[0][0]
        self.assertEqual(request.full_url, dictate.ENDPOINT)
        self.assertEqual(request.get_header("Authorization"), "Bearer test")
        self.assertNotIn("Authorization", request.headers)
        payload = json.loads(request.data)
        system, user = payload["messages"]
        self.assertNotIn("{{", system["content"])
        self.assertEqual(dictate.base64.b64decode(user["content"][0]["input_audio"]["data"]), audio)

    @unittest.skipUnless(os.environ.get("DNT_ALSA_TEST"), "requires ALSA null PCM")
    def test_linux_capture(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "audio.wav"
            dictate.record(path, 1, "null")
            self.assertTrue(dictate.read_audio(path))
