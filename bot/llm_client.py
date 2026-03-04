"""LLM client supporting Anthropic and OpenAI-compatible APIs."""

import json
import logging
import re

import anthropic
import openai

from config import Settings
from prompts import SYSTEM_PROMPT

logger = logging.getLogger(__name__)


class LLMClient:
    def __init__(self, config: Settings):
        self.config = config

    async def review(self, user_prompt: str) -> dict:
        """Send the review prompt to the configured LLM and return parsed JSON."""
        if self.config.LLM_PROVIDER == "anthropic":
            raw = await self._call_anthropic(user_prompt)
        else:
            raw = await self._call_openai_compatible(user_prompt)

        return self.parse_json_response(raw)

    async def _call_anthropic(self, user_prompt: str) -> str:
        client = anthropic.AsyncAnthropic(api_key=self.config.LLM_API_KEY)
        try:
            message = await client.messages.create(
                model=self.config.LLM_MODEL,
                max_tokens=self.config.LLM_MAX_TOKENS,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": user_prompt}],
            )
            return message.content[0].text
        finally:
            await client.close()

    async def _call_openai_compatible(self, user_prompt: str) -> str:
        client = openai.AsyncOpenAI(
            api_key=self.config.LLM_API_KEY or "no-key",
            base_url=self.config.LLM_API_BASE,
        )
        try:
            response = await client.chat.completions.create(
                model=self.config.LLM_MODEL,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": user_prompt},
                ],
                max_tokens=self.config.LLM_MAX_TOKENS,
            )
            return response.choices[0].message.content
        finally:
            await client.close()

    @staticmethod
    def parse_json_response(text: str) -> dict:
        """Parse JSON from LLM response, handling various formats.

        Handles:
        - Bare JSON objects
        - ```json fenced code blocks
        - JSON embedded within other text
        """
        text = text.strip()

        # Try bare JSON first
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            pass

        # Try ```json code blocks
        match = re.search(r"```(?:json)?\s*\n?(.*?)\n?\s*```", text, re.DOTALL)
        if match:
            try:
                return json.loads(match.group(1).strip())
            except json.JSONDecodeError:
                pass

        # Try to find embedded JSON object
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1 and end > start:
            try:
                return json.loads(text[start : end + 1])
            except json.JSONDecodeError:
                pass

        logger.error("Failed to parse JSON from LLM response: %s", text[:200])
        raise ValueError(f"Could not parse JSON from LLM response: {text[:200]}")
