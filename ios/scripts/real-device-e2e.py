#!/usr/bin/env python3
"""Run WLOC's real-device smoke test through a preinstalled WebDriverAgent.

The script intentionally keeps the iOS 17+ userspace tunnel, XCTest runner,
and WDA client in one process.  This makes it work from Windows even when the
phone is only reachable through Apple's network usbmux connection.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import time
from contextlib import suppress
from pathlib import Path
from xml.etree import ElementTree

from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.services.dvt.testmanaged.xcuitest import TestConfig, XCUITestService
from pymobiledevice3.services.wda import DEFAULT_WDA_PORT, WdaServiceClient
from pymobiledevice3.exceptions import WdaError


class WdaStartupError(RuntimeError):
    """Raised only before the first app session, when replaying a scenario is still safe."""


class DirectRsdProvider:
    """Keep WDA traffic on the userspace RSD dialer instead of usbmux port forwarding."""

    def __init__(self, rsd) -> None:
        self.rsd = rsd

    async def create_service_connection(self, port: int):
        return await self.rsd.create_service_connection(port)


def trace(message: str) -> None:
    print(f"[wloc-e2e] {message}", flush=True)


async def wait_for_wda(rsd, runner_task: asyncio.Task, timeout: float = 45.0) -> None:
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        if runner_task.done():
            runner_task.result()
            raise RuntimeError("WebDriverAgent exited before its HTTP endpoint became ready")
        try:
            connection = await rsd.create_service_connection(DEFAULT_WDA_PORT)
        except Exception:
            await asyncio.sleep(0.2)
            continue
        async with connection:
            return
    raise TimeoutError(f"WebDriverAgent did not open port {DEFAULT_WDA_PORT} within {timeout:.0f}s")


async def wait_for_wda_status(
    client: WdaServiceClient, runner_task: asyncio.Task, timeout: float = 45.0
) -> dict:
    deadline = asyncio.get_running_loop().time() + timeout
    last_error: Exception | None = None
    while asyncio.get_running_loop().time() < deadline:
        if runner_task.done():
            runner_task.result()
            raise RuntimeError("WebDriverAgent exited before returning a status response")
        try:
            return await client.get_status()
        except Exception as error:
            last_error = error
            await asyncio.sleep(0.25)
    raise TimeoutError(f"WebDriverAgent did not return status within {timeout:.0f}s: {last_error}")


async def capture(client: WdaServiceClient, session_id: str, output_dir: Path, name: str) -> dict:
    screenshot_path = output_dir / f"{name}.png"
    source_path = output_dir / f"{name}.xml"
    screenshot_path.write_bytes(await client.get_screenshot(session_id=session_id))
    source_path.write_text(await client.get_source(session_id=session_id), encoding="utf-8")
    return {"screenshot": str(screenshot_path), "source": str(source_path)}


async def capture_global(client: WdaServiceClient, output_dir: Path, name: str) -> dict:
    screenshot_path = output_dir / f"{name}.png"
    source_path = output_dir / f"{name}.xml"
    screenshot_path.write_bytes(await client.get_screenshot())
    source_path.write_text(await client.get_source(), encoding="utf-8")
    return {"screenshot": str(screenshot_path), "source": str(source_path)}


async def find_first(client: WdaServiceClient, session_id: str, candidates: list[tuple[str, str]]) -> str:
    last_error: Exception | None = None
    for using, value in candidates:
        try:
            return await client.find_element(using=using, value=value, session_id=session_id)
        except WdaError as error:
            last_error = error
    raise RuntimeError(f"None of the expected UI elements were found: {candidates}; last error: {last_error}")


async def tap_first(client: WdaServiceClient, session_id: str, candidates: list[tuple[str, str]]) -> None:
    element_id = await find_first(client, session_id, candidates)
    await client.click(element_id=element_id, session_id=session_id)


async def wait_for_first(
    client: WdaServiceClient,
    session_id: str,
    candidates: list[tuple[str, str]],
    timeout: float = 20.0,
) -> str:
    deadline = asyncio.get_running_loop().time() + timeout
    last_error: Exception | None = None
    while asyncio.get_running_loop().time() < deadline:
        try:
            return await find_first(client, session_id, candidates)
        except Exception as error:
            last_error = error
            await asyncio.sleep(0.35)
    raise TimeoutError(f"Timed out waiting for {candidates}: {last_error}")


async def element_exists(
    client: WdaServiceClient, session_id: str, candidates: list[tuple[str, str]]
) -> bool:
    try:
        await find_first(client, session_id, candidates)
        return True
    except Exception:
        return False


async def wait_for_source_text(
    client: WdaServiceClient,
    session_id: str,
    text: str,
    timeout: float = 20.0,
) -> str:
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        source = await client.get_source(session_id=session_id)
        if text in source:
            return source
        await asyncio.sleep(0.35)
    raise TimeoutError(f"Timed out waiting for UI text: {text}")


def frame_for_node_containing(source: str, element_type: str, text: str) -> tuple[int, int, int, int]:
    root = ElementTree.fromstring(source)
    for element in root.iter(element_type):
        if any(text in value for node in element.iter() for value in node.attrib.values()):
            return tuple(int(element.attrib[key]) for key in ("x", "y", "width", "height"))
    raise RuntimeError(f"No {element_type} contains expected text: {text}")


def accessibility_value(source: str, name: str) -> str | None:
    root = ElementTree.fromstring(source)
    for element in root.iter():
        if element.attrib.get("name") == name:
            return element.attrib.get("value") or element.attrib.get("label")
    return None


async def wait_for_accessibility_value_change(
    client: WdaServiceClient,
    session_id: str,
    name: str,
    previous_value: str | None,
    timeout: float = 20.0,
) -> str:
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        source = await client.get_source(session_id=session_id)
        value = accessibility_value(source, name)
        if value is not None and value != previous_value:
            return value
        await asyncio.sleep(0.35)
    raise TimeoutError(f"Timed out waiting for {name} to change from {previous_value}")


async def tap_at(client: WdaServiceClient, session_id: str, x: int, y: int) -> None:
    await client._request_json(
        "POST",
        f"/session/{session_id}/wda/tap",
        {"x": x, "y": y},
    )


async def configure_fast_ui(client: WdaServiceClient, session_id: str) -> None:
    await client._request_json(
        "POST",
        f"/session/{session_id}/appium/settings",
        {"settings": {"waitForIdleTimeout": 0}},
    )


async def start_app_session(client: WdaServiceClient, bundle_id: str) -> str:
    last_error: Exception | None = None
    for attempt in range(1, 5):
        try:
            session_id = await client.start_session(bundle_id=bundle_id)
            await configure_fast_ui(client, session_id)
            trace(f"session started for {bundle_id}")
            return session_id
        except Exception as error:
            last_error = error
            if attempt == 4:
                break
            trace(f"session start retry {attempt}/4 for {bundle_id}: {error}")
            await asyncio.sleep(1.5)
    raise RuntimeError(f"Could not start a WDA session for {bundle_id}: {last_error}")


def source_elements(source: str, element_type: str) -> list[dict[str, str]]:
    root = ElementTree.fromstring(source)
    return [element.attrib for element in root.iter(element_type)]


def shadowrocket_is_connected(source: str) -> bool:
    switches = source_elements(source, "XCUIElementTypeSwitch")
    if switches:
        return switches[0].get("value", "").strip().lower() in {"1", "true", "on"}
    return ("已连接" in source or "Connected" in source) and not (
        "未连接" in source or "Not Connected" in source
    )


async def ensure_location_services(
    client: WdaServiceClient,
    session_id: str,
    enabled: bool,
    output_dir: Path,
    evidence_name: str,
) -> dict:
    trace(f"ensuring Location Services is {'on' if enabled else 'off'}")
    source = await client.get_source(session_id=session_id)
    switches = source_elements(source, "XCUIElementTypeSwitch")
    location_switches = [
        item
        for item in switches
        if "定位服务" in item.get("name", "") or "Location Services" in item.get("name", "")
    ]
    if not location_switches:
        trace("opening Location Services through Settings search")
        await tap_first(client, session_id, [("class name", "XCUIElementTypeSearchField")])
        await client.send_keys("定位服务", session_id=session_id)
        await asyncio.sleep(2)
        await tap_first(
            client,
            session_id,
            [
                ("xpath", '//XCUIElementTypeButton[contains(@name,"定位服务")][1]'),
                ("xpath", '(//XCUIElementTypeButton[@x="20"])[1]'),
            ],
        )
        await asyncio.sleep(1)
        source = await client.get_source(session_id=session_id)
        switches = source_elements(source, "XCUIElementTypeSwitch")
        location_switches = [
            item
            for item in switches
            if "定位服务" in item.get("name", "")
            or "Location Services" in item.get("name", "")
        ]
    if not location_switches and enabled:
        trace("dismissing the system Location Services prompt and retrying Settings search")
        await tap_at(client, session_id, 294, 542)
        await asyncio.sleep(1)
        await tap_first(client, session_id, [("class name", "XCUIElementTypeSearchField")])
        await client.send_keys("定位服务", session_id=session_id)
        await asyncio.sleep(2)
        await tap_first(
            client,
            session_id,
            [
                ("xpath", '//XCUIElementTypeButton[contains(@name,"定位服务")][1]'),
                ("xpath", '(//XCUIElementTypeButton[@x="20"])[1]'),
            ],
        )
        await asyncio.sleep(1)
        source = await client.get_source(session_id=session_id)
        switches = source_elements(source, "XCUIElementTypeSwitch")
        location_switches = [
            item
            for item in switches
            if "定位服务" in item.get("name", "")
            or "Location Services" in item.get("name", "")
        ]
    if not location_switches and len(switches) == 1:
        location_switches = switches
    if not location_switches:
        raise RuntimeError("The Location Services switch was not found in iOS Settings")

    switch = location_switches[0]
    value = switch.get("value", "").strip().lower()
    is_enabled = value in {"1", "true", "on"}
    if is_enabled != enabled:
        physical_switch = next(
            (
                item
                for item in switches
                if not item.get("name")
                and item.get("value", "").strip().lower() == value
            ),
            None,
        )
        if physical_switch is not None:
            x = int(physical_switch["x"]) + int(physical_switch["width"]) // 2
            y = int(physical_switch["y"]) + int(physical_switch["height"]) // 2
            await tap_at(client, session_id, x, y)
        else:
            await tap_first(
                client,
                session_id,
                [("xpath", "//XCUIElementTypeSwitch[last()]")],
            )

        if not enabled:
            await asyncio.sleep(0.75)
            post_tap_source = await client.get_source(session_id=session_id)
            has_confirmation = bool(
                source_elements(post_tap_source, "XCUIElementTypeAlert")
                or source_elements(post_tap_source, "XCUIElementTypeSheet")
            )
            if has_confirmation:
                confirm_id = await wait_for_first(
                    client,
                    session_id,
                    [
                        ("xpath", '//XCUIElementTypeAlert//XCUIElementTypeButton[@name="关闭"]'),
                        ("xpath", '//XCUIElementTypeAlert//XCUIElementTypeButton[@name="Turn Off"]'),
                        ("xpath", "//XCUIElementTypeAlert//XCUIElementTypeButton[last()]"),
                        ("xpath", '//XCUIElementTypeSheet//XCUIElementTypeButton[@name="关闭"]'),
                        ("xpath", '//XCUIElementTypeSheet//XCUIElementTypeButton[@name="Turn Off"]'),
                        ("xpath", "//XCUIElementTypeSheet//XCUIElementTypeButton[last()]"),
                    ],
                    timeout=6,
                )
                await client.click(element_id=confirm_id, session_id=session_id)
        await asyncio.sleep(1.5)

    final_source = await client.get_source(session_id=session_id)
    if enabled is False and (
        source_elements(final_source, "XCUIElementTypeAlert")
        or source_elements(final_source, "XCUIElementTypeSheet")
    ):
        raise RuntimeError("The Location Services confirmation alert is still visible")
    final_switches = source_elements(final_source, "XCUIElementTypeSwitch")
    final_candidates = [
        item
        for item in final_switches
        if "定位服务" in item.get("name", "") or "Location Services" in item.get("name", "")
    ]
    if not final_candidates and len(final_switches) == 1:
        final_candidates = final_switches
    if not final_candidates:
        raise RuntimeError("The Location Services switch disappeared after it was toggled")
    final_value = final_candidates[0].get("value", "").strip().lower()
    final_enabled = final_value in {"1", "true", "on"}
    if final_enabled != enabled:
        raise RuntimeError(
            f"Location Services did not change to {'on' if enabled else 'off'}; value={final_value!r}"
        )
    return await capture(client, session_id, output_dir, evidence_name)


async def grant_location_permission(
    client: WdaServiceClient, session_id: str, output_dir: Path
) -> list[dict]:
    evidence: list[dict] = []
    evidence.append(await capture(client, session_id, output_dir, "settings-root"))
    await tap_first(client, session_id, [("class name", "XCUIElementTypeSearchField")])
    await client.send_keys("WLOC", session_id=session_id)
    await asyncio.sleep(2)
    evidence.append(await capture(client, session_id, output_dir, "settings-search-wloc"))
    await tap_first(
        client,
        session_id,
        [
            ("xpath", '(//XCUIElementTypeButton[@name="WLOC、App"])[2]'),
            ("xpath", '(//XCUIElementTypeStaticText[@name="WLOC"])[2]'),
        ],
    )
    await asyncio.sleep(1)
    evidence.append(await capture(client, session_id, output_dir, "settings-wloc"))
    await tap_first(client, session_id, [("name", "位置")])
    await asyncio.sleep(1)
    evidence.append(await capture(client, session_id, output_dir, "settings-wloc-location"))
    await tap_first(
        client,
        session_id,
        [
            ("name", "我共享时"),
            ("name", "使用 App 时"),
        ],
    )
    await asyncio.sleep(1)
    evidence.append(await capture(client, session_id, output_dir, "settings-wloc-location-granted"))
    return evidence


async def probe_location_settings(
    client: WdaServiceClient, session_id: str, output_dir: Path
) -> list[dict]:
    return [
        await ensure_location_services(
            client,
            session_id,
            enabled=True,
            output_dir=output_dir,
            evidence_name="location-services-on",
        )
    ]


async def probe_location_settings_search(
    client: WdaServiceClient, session_id: str, output_dir: Path
) -> list[dict]:
    trace("capturing Settings root")
    evidence = [await capture(client, session_id, output_dir, "location-settings-root")]
    trace("opening Settings search")
    await tap_first(client, session_id, [("class name", "XCUIElementTypeSearchField")])
    await client.send_keys("定位服务", session_id=session_id)
    await asyncio.sleep(2)
    trace("capturing Location Services search results")
    evidence.append(await capture(client, session_id, output_dir, "location-settings-search"))
    trace("opening the Location Services result")
    await tap_first(
        client,
        session_id,
        [
            ("xpath", '//XCUIElementTypeButton[contains(@name,"定位服务")][1]'),
            ("xpath", '(//XCUIElementTypeButton[@x="20"])[1]'),
        ],
    )
    await asyncio.sleep(1)
    trace("capturing the Location Services page")
    evidence.append(await capture(client, session_id, output_dir, "location-services-page"))
    return evidence


async def location_services_roundtrip(
    client: WdaServiceClient, session_id: str, output_dir: Path
) -> list[dict]:
    evidence: list[dict] = []
    try:
        evidence.append(
            await ensure_location_services(
                client,
                session_id,
                enabled=False,
                output_dir=output_dir,
                evidence_name="location-services-off",
            )
        )
    finally:
        evidence.append(
            await ensure_location_services(
                client,
                session_id,
                enabled=True,
                output_dir=output_dir,
                evidence_name="location-services-restored-on",
            )
        )
    return evidence


async def validate_shadowrocket_module(
    client: WdaServiceClient, session_id: str, output_dir: Path
) -> list[dict]:
    evidence = [await capture(client, session_id, output_dir, "wloc-home-before-module-check")]
    trace("opening WLOC Shadowrocket settings")
    await tap_first(client, session_id, [("accessibility id", "wloc.settings")])
    await wait_for_first(
        client,
        session_id,
        [("accessibility id", "wloc.settings.screen")],
        timeout=15,
    )
    await asyncio.sleep(5)
    evidence.append(await capture(client, session_id, output_dir, "wloc-module-check"))
    module_source = await client.get_source(session_id=session_id)
    if await element_exists(
        client,
        session_id,
        [("accessibility id", "wloc.settings.finish-setup")],
    ) or ("模块可用" not in module_source and "Module available" not in module_source):
        raise RuntimeError("The WLOC Shadowrocket module did not return a valid response")
    return evidence


async def wait_for_workflow(
    client: WdaServiceClient,
    session_id: str,
    expected_identifier: str,
    timeout: float = 60.0,
) -> str:
    trace(f"waiting for {expected_identifier}")
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        if await element_exists(
            client,
            session_id,
            [("accessibility id", expected_identifier)],
        ):
            trace(f"reached {expected_identifier}")
            return expected_identifier
        if await element_exists(
            client,
            session_id,
            [("accessibility id", "wloc.workflow.failed")],
        ):
            return "wloc.workflow.failed"
        if await element_exists(
            client,
            session_id,
            [
                ("xpath", "//XCUIElementTypeAlert"),
                ("xpath", "//XCUIElementTypeSheet"),
            ],
        ):
            return "system-modal"
        await asyncio.sleep(0.5)
    raise TimeoutError(f"Timed out waiting for {expected_identifier}")


async def require_workflow(
    client: WdaServiceClient,
    session_id: str,
    output_dir: Path,
    expected_identifier: str,
    evidence_name: str,
    timeout: float = 60.0,
) -> dict:
    result = await wait_for_workflow(client, session_id, expected_identifier, timeout=timeout)
    evidence = await capture(client, session_id, output_dir, evidence_name)
    if result != expected_identifier:
        raise RuntimeError(
            f"Expected {expected_identifier}, but the device reached {result}; evidence={evidence}"
        )
    return evidence


async def close_shadowrocket_settings(client: WdaServiceClient, session_id: str) -> None:
    await tap_first(
        client,
        session_id,
        [
            ("accessibility id", "关闭"),
            ("accessibility id", "Close"),
            ("xpath", "//XCUIElementTypeNavigationBar//XCUIElementTypeButton[1]"),
        ],
    )


async def delete_saved_places_matching(
    client: WdaServiceClient,
    session_id: str,
    coordinate_text: str,
) -> int:
    deleted = 0
    while True:
        source = await client.get_source(session_id=session_id)
        try:
            x, y, width, height = frame_for_node_containing(
                source,
                "XCUIElementTypeCell",
                coordinate_text,
            )
        except RuntimeError:
            return deleted
        await client.swipe(
            x + width - 20,
            y + height // 2,
            x + 80,
            y + height // 2,
            duration=0.8,
            session_id=session_id,
        )
        await asyncio.sleep(0.75)
        await tap_first(
            client,
            session_id,
            [
                ("accessibility id", "删除"),
                ("accessibility id", "Delete"),
                ("xpath", '//XCUIElementTypeButton[@name="删除" or @name="Delete"]'),
            ],
        )
        deleted += 1
        await asyncio.sleep(0.75)


async def dismiss_finished_workflow(client: WdaServiceClient, session_id: str) -> bool:
    if not await element_exists(
        client,
        session_id,
        [
            ("accessibility id", "wloc.workflow.completed"),
            ("accessibility id", "wloc.workflow.failed"),
        ],
    ):
        return False
    await tap_first(
        client,
        session_id,
        [
            ("accessibility id", "wloc.workflow.primary"),
            ("xpath", '//XCUIElementTypeButton[@name="wloc.workflow.completed"]'),
            ("xpath", '//XCUIElementTypeButton[@name="wloc.workflow.failed"]'),
            ("xpath", '//XCUIElementTypeButton[@label="完成"]'),
            ("xpath", '//XCUIElementTypeButton[@label="知道了"]'),
        ],
    )
    await asyncio.sleep(1)
    await wait_for_first(
        client,
        session_id,
        [("accessibility id", "wloc.map")],
        timeout=15,
    )
    return True


async def run_location_cycle(
    client: WdaServiceClient,
    wloc_bundle_id: str,
    output_dir: Path,
    action_identifier: str,
    evidence_prefix: str,
    action_session_id: str | None = None,
) -> list[dict]:
    settings_bundle_id = "com.apple.Preferences"
    evidence: list[dict] = []

    wloc_session = action_session_id or await start_app_session(client, wloc_bundle_id)
    await asyncio.sleep(1.5)
    trace(f"starting {evidence_prefix} workflow")
    await tap_first(client, wloc_session, [("accessibility id", action_identifier)])
    await asyncio.sleep(3)

    wloc_session = await start_app_session(client, wloc_bundle_id)
    evidence.append(
        await require_workflow(
            client,
            wloc_session,
            output_dir,
            "wloc.workflow.location-off",
            f"{evidence_prefix}-waiting-location-off",
            timeout=45,
        )
    )

    settings_session = await start_app_session(client, settings_bundle_id)
    evidence.append(
        await ensure_location_services(
            client,
            settings_session,
            enabled=False,
            output_dir=output_dir,
            evidence_name=f"{evidence_prefix}-location-services-off",
        )
    )

    wloc_session = await start_app_session(client, wloc_bundle_id)
    await asyncio.sleep(4)
    wloc_session = await start_app_session(client, wloc_bundle_id)
    evidence.append(
        await require_workflow(
            client,
            wloc_session,
            output_dir,
            "wloc.workflow.location-on",
            f"{evidence_prefix}-waiting-location-on",
            timeout=45,
        )
    )

    settings_session = await start_app_session(client, settings_bundle_id)
    evidence.append(
        await ensure_location_services(
            client,
            settings_session,
            enabled=True,
            output_dir=output_dir,
            evidence_name=f"{evidence_prefix}-location-services-on",
        )
    )

    wloc_session = await start_app_session(client, wloc_bundle_id)
    evidence.append(
        await require_workflow(
            client,
            wloc_session,
            output_dir,
            "wloc.workflow.completed",
            f"{evidence_prefix}-completed",
            timeout=75,
        )
    )
    await dismiss_finished_workflow(client, wloc_session)
    evidence.append(
        await capture(client, wloc_session, output_dir, f"{evidence_prefix}-home-after-completion")
    )
    return evidence


async def full_location_roundtrip(
    client: WdaServiceClient,
    initial_session_id: str,
    wloc_bundle_id: str,
    output_dir: Path,
) -> list[dict]:
    await dismiss_finished_workflow(client, initial_session_id)
    evidence = await validate_shadowrocket_module(client, initial_session_id, output_dir)
    await close_shadowrocket_settings(client, initial_session_id)
    await asyncio.sleep(1)

    trace("selecting a map target away from the real device position")
    await tap_at(client, initial_session_id, 220, 360)
    await wait_for_first(
        client,
        initial_session_id,
        [("accessibility id", "wloc.selected-coordinate")],
        timeout=15,
    )
    evidence.append(await capture(client, initial_session_id, output_dir, "wloc-target-selected"))

    try:
        evidence.extend(
            await run_location_cycle(
                client,
                wloc_bundle_id,
                output_dir,
                action_identifier="wloc.apply-location",
                evidence_prefix="apply-fake-location",
                action_session_id=initial_session_id,
            )
        )
        evidence.extend(
            await run_location_cycle(
                client,
                wloc_bundle_id,
                output_dir,
                action_identifier="wloc.restore-location",
                evidence_prefix="restore-real-location",
            )
        )
    except Exception:
        trace("workflow failed; restoring the global Location Services switch before exiting")
        with suppress(Exception):
            settings_session = await start_app_session(client, "com.apple.Preferences")
            await ensure_location_services(
                client,
                settings_session,
                enabled=True,
                output_dir=output_dir,
                evidence_name="failure-cleanup-location-services-on",
            )
        raise
    return evidence


async def restore_only(
    client: WdaServiceClient,
    initial_session_id: str,
    wloc_bundle_id: str,
    output_dir: Path,
) -> list[dict]:
    await dismiss_finished_workflow(client, initial_session_id)
    return await run_location_cycle(
        client,
        wloc_bundle_id,
        output_dir,
        action_identifier="wloc.restore-location",
        evidence_prefix="restore-real-location",
        action_session_id=initial_session_id,
    )


async def map_features(
    client: WdaServiceClient,
    session_id: str,
    output_dir: Path,
) -> list[dict]:
    evidence: list[dict] = []
    await dismiss_finished_workflow(client, session_id)

    trace("checking coordinate parsing from the search sheet")
    await tap_first(client, session_id, [("accessibility id", "wloc.search")])
    coordinate_field = await wait_for_first(
        client,
        session_id,
        [
            ("accessibility id", "粘贴 Apple/高德链接或纬度,经度"),
            ("xpath", '//XCUIElementTypeTextField[contains(@value,"粘贴 Apple")]'),
        ],
    )
    await client.click(element_id=coordinate_field, session_id=session_id)
    await client.send_keys("23.129100, 113.264400", session_id=session_id)
    await tap_first(client, session_id, [("accessibility id", "解析并选择")])
    await wait_for_first(client, session_id, [("accessibility id", "wloc.map")])
    await wait_for_source_text(client, session_id, "23.129100, 113.264400")
    evidence.append(await capture(client, session_id, output_dir, "map-coordinate-parsed"))

    trace("checking saved-place roundtrip")
    await tap_first(client, session_id, [("accessibility id", "wloc.saved-places")])
    deleted = await delete_saved_places_matching(client, session_id, "23.129100, 113.264400")
    if deleted:
        trace(f"removed {deleted} stale temporary saved place(s)")
    await tap_first(client, session_id, [("accessibility id", "关闭")])
    await tap_first(client, session_id, [("accessibility id", "收藏")])
    await tap_first(client, session_id, [("accessibility id", "wloc.saved-places")])
    await wait_for_source_text(client, session_id, "收藏位置")
    await wait_for_source_text(client, session_id, "23.129100, 113.264400")
    evidence.append(await capture(client, session_id, output_dir, "map-saved-place-listed"))
    await tap_first(
        client,
        session_id,
        [("xpath", '//XCUIElementTypeButton[contains(@name,"23.129100")]')],
    )
    await wait_for_first(client, session_id, [("accessibility id", "wloc.map")])
    await wait_for_source_text(client, session_id, "23.129100, 113.264400")
    evidence.append(await capture(client, session_id, output_dir, "map-saved-place-selected"))

    trace("removing the temporary saved place")
    await tap_first(client, session_id, [("accessibility id", "wloc.saved-places")])
    deleted = await delete_saved_places_matching(client, session_id, "23.129100, 113.264400")
    if deleted != 1:
        raise RuntimeError(f"Expected to remove one temporary saved place, removed {deleted}")
    evidence.append(await capture(client, session_id, output_dir, "map-saved-place-cleaned"))
    await tap_first(client, session_id, [("accessibility id", "关闭")])

    trace("checking MapKit place search")
    await tap_first(client, session_id, [("accessibility id", "wloc.search")])
    query_field = await wait_for_first(
        client,
        session_id,
        [
            ("accessibility id", "地点、地址"),
            ("xpath", '//XCUIElementTypeTextField[contains(@value,"地点、地址")]'),
        ],
    )
    await client.click(element_id=query_field, session_id=session_id)
    await client.send_keys("广州塔\n", session_id=session_id)
    search_result = await wait_for_first(
        client,
        session_id,
        [("xpath", '//XCUIElementTypeButton[contains(@name,"广州塔")]')],
        timeout=30,
    )
    evidence.append(await capture(client, session_id, output_dir, "map-search-results"))
    await client.click(element_id=search_result, session_id=session_id)
    await wait_for_first(client, session_id, [("accessibility id", "wloc.map")])
    await wait_for_source_text(client, session_id, "广州塔")
    evidence.append(await capture(client, session_id, output_dir, "map-search-selected"))

    trace("checking current-location selection")
    source = await client.get_source(session_id=session_id)
    previous_coordinate = accessibility_value(source, "wloc.selected-coordinate")
    await tap_first(client, session_id, [("accessibility id", "wloc.current-location")])
    try:
        selected_coordinate = await wait_for_accessibility_value_change(
            client,
            session_id,
            "wloc.selected-coordinate",
            previous_coordinate,
            timeout=12,
        )
    except TimeoutError:
        if await element_exists(
            client,
            session_id,
            [
                ("xpath", '//XCUIElementTypeAlert//XCUIElementTypeButton[@name="好"]'),
                ("xpath", "//XCUIElementTypeAlert//XCUIElementTypeButton[last()]"),
            ],
        ):
            await tap_first(
                client,
                session_id,
                [
                    ("xpath", '//XCUIElementTypeAlert//XCUIElementTypeButton[@name="好"]'),
                    ("xpath", "//XCUIElementTypeAlert//XCUIElementTypeButton[last()]"),
                ],
            )
        await asyncio.sleep(3)
        await tap_first(client, session_id, [("accessibility id", "wloc.current-location")])
        selected_coordinate = await wait_for_accessibility_value_change(
            client,
            session_id,
            "wloc.selected-coordinate",
            previous_coordinate,
            timeout=20,
        )
    trace(f"current-location selection changed coordinate to {selected_coordinate}")
    evidence.append(await capture(client, session_id, output_dir, "map-current-location"))
    return evidence


async def config_picker_cancel(
    client: WdaServiceClient,
    session_id: str,
    output_dir: Path,
) -> list[dict]:
    evidence: list[dict] = []
    await dismiss_finished_workflow(client, session_id)
    trace("opening the Shadowrocket configuration file picker")
    await tap_first(client, session_id, [("accessibility id", "wloc.settings")])
    await wait_for_first(client, session_id, [("accessibility id", "wloc.settings.screen")])
    had_pending_share = await element_exists(
        client,
        session_id,
        [("accessibility id", "交给 Shadowrocket 打开")],
    )
    await tap_first(client, session_id, [("accessibility id", "选择配置文件")])
    await wait_for_first(
        client,
        session_id,
        [
            ("accessibility id", "取消"),
            ("accessibility id", "Cancel"),
            ("xpath", '//XCUIElementTypeButton[@name="取消" or @name="Cancel"]'),
        ],
        timeout=20,
    )
    evidence.append(await capture(client, session_id, output_dir, "config-file-picker-open"))
    await tap_first(
        client,
        session_id,
        [
            ("accessibility id", "取消"),
            ("accessibility id", "Cancel"),
            ("xpath", '//XCUIElementTypeButton[@name="取消" or @name="Cancel"]'),
        ],
    )
    await wait_for_first(client, session_id, [("accessibility id", "wloc.settings.screen")])
    has_pending_share = await element_exists(
        client,
        session_id,
        [("accessibility id", "交给 Shadowrocket 打开")],
    )
    if has_pending_share != had_pending_share:
        raise RuntimeError("Cancelling the file picker unexpectedly changed pending import state")
    if await element_exists(client, session_id, [("accessibility id", "无法读取文件")]):
        raise RuntimeError("Cancelling the file picker incorrectly produced a read failure")
    evidence.append(await capture(client, session_id, output_dir, "config-file-picker-cancelled"))
    await tap_first(client, session_id, [("accessibility id", "关闭")])
    await wait_for_first(client, session_id, [("accessibility id", "wloc.map")])
    return evidence


async def final_connection_state(
    client: WdaServiceClient,
    wloc_bundle_id: str,
    output_dir: Path,
) -> list[dict]:
    evidence: list[dict] = []
    trace("requesting the final Shadowrocket connection through WLOC")
    wloc_session = await start_app_session(client, wloc_bundle_id)
    await dismiss_finished_workflow(client, wloc_session)
    await tap_first(client, wloc_session, [("accessibility id", "wloc.settings")])
    await wait_for_first(
        client,
        wloc_session,
        [("accessibility id", "wloc.settings.screen")],
        timeout=15,
    )
    await tap_first(
        client,
        wloc_session,
        [
            ("accessibility id", "发出连接指令"),
            ("accessibility id", "Send Connect Command"),
        ],
    )
    await asyncio.sleep(4)

    trace("capturing the foreground Shadowrocket without relaunching it")
    evidence.append(await capture_global(client, output_dir, "shadowrocket-connect-command-state"))
    shadowrocket_source = await client.get_source()
    is_connected = shadowrocket_is_connected(shadowrocket_source)
    if not is_connected:
        trace("connect URL did not start the tunnel; trying Shadowrocket's documented open URL")
        wloc_session = await start_app_session(client, wloc_bundle_id)
        await tap_first(client, wloc_session, [("accessibility id", "wloc.settings")])
        await wait_for_first(
            client,
            wloc_session,
            [("accessibility id", "wloc.settings.screen")],
            timeout=15,
        )
        await tap_first(
            client,
            wloc_session,
            [("accessibility id", "wloc.settings.open-shadowrocket")],
        )
        await asyncio.sleep(4)
        shadowrocket_source = await client.get_source()
        is_connected = shadowrocket_is_connected(shadowrocket_source)
    evidence.append(await capture_global(client, output_dir, "shadowrocket-final-state"))
    if not is_connected:
        raise RuntimeError("Neither Shadowrocket connect nor open URL reported a connected state")

    trace("returning to WLOC and verifying the connected module is reachable")
    wloc_session = await start_app_session(client, wloc_bundle_id)
    await dismiss_finished_workflow(client, wloc_session)
    evidence.extend(await validate_shadowrocket_module(client, wloc_session, output_dir))
    await close_shadowrocket_settings(client, wloc_session)
    return evidence


async def recover_shadowrocket_with_ui(
    client: WdaServiceClient,
    wloc_bundle_id: str,
    output_dir: Path,
) -> list[dict]:
    evidence: list[dict] = []
    trace("opening Shadowrocket through WLOC without restarting the VPN app")
    wloc_session = await start_app_session(client, wloc_bundle_id)
    await dismiss_finished_workflow(client, wloc_session)
    await tap_first(client, wloc_session, [("accessibility id", "wloc.settings")])
    await wait_for_first(
        client,
        wloc_session,
        [("accessibility id", "wloc.settings.screen")],
        timeout=15,
    )
    await tap_first(
        client,
        wloc_session,
        [("accessibility id", "wloc.settings.open-shadowrocket")],
    )
    await asyncio.sleep(2)
    source = await client.get_source()
    is_connected = shadowrocket_is_connected(source)
    if not is_connected:
        switches = source_elements(source, "XCUIElementTypeSwitch")
        if not switches:
            raise RuntimeError("Shadowrocket connection switch was not exposed to UI automation")
        trace("tapping the Shadowrocket connection switch as a simulated user")
        connection_switch = switches[0]
        switch_x = int(float(connection_switch["x"]))
        switch_y = int(float(connection_switch["y"]))
        switch_width = int(float(connection_switch["width"]))
        switch_height = int(float(connection_switch["height"]))
        await tap_at(
            client,
            wloc_session,
            switch_x + switch_width // 2,
            switch_y + switch_height // 2,
        )
        await asyncio.sleep(5)
    evidence.append(await capture_global(client, output_dir, "shadowrocket-ui-recovered"))
    source = await client.get_source()
    is_connected = shadowrocket_is_connected(source)
    if not is_connected:
        raise RuntimeError("Shadowrocket remained disconnected after the simulated user tap")

    trace("verifying WLOC module communication after UI recovery")
    wloc_session = await start_app_session(client, wloc_bundle_id)
    await dismiss_finished_workflow(client, wloc_session)
    evidence.extend(await validate_shadowrocket_module(client, wloc_session, output_dir))
    await close_shadowrocket_settings(client, wloc_session)
    return evidence


async def run_probe(args: argparse.Namespace) -> dict:
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    async with UserspaceRsdTunnel(serial=args.udid) as rsd:
        trace("userspace RSD tunnel is ready")
        config = await TestConfig.create_for(rsd, runner_bundle_id=args.runner_bundle_id)
        runner_task = asyncio.create_task(XCUITestService(rsd).run(config), name="wloc-wda-runner")
        try:
            try:
                await asyncio.sleep(2)
                await wait_for_wda(rsd, runner_task)
                trace("WebDriverAgent port is open")
                client = WdaServiceClient(service_provider=DirectRsdProvider(rsd), timeout=args.timeout)
                status = await wait_for_wda_status(client, runner_task)
                trace("WebDriverAgent status is ready")
                session_id = await start_app_session(client, args.app_bundle_id)
            except Exception as error:
                raise WdaStartupError(f"WebDriverAgent startup failed: {error}") from error
            if args.scenario == "grant-location":
                evidence = await grant_location_permission(client, session_id, output_dir)
            elif args.scenario == "global-probe":
                evidence = [await capture_global(client, output_dir, "global-probe")]
            elif args.scenario == "location-search-probe":
                evidence = await probe_location_settings_search(client, session_id, output_dir)
            elif args.scenario == "location-toggle-roundtrip":
                evidence = await location_services_roundtrip(client, session_id, output_dir)
            elif args.scenario == "module-check":
                evidence = await validate_shadowrocket_module(client, session_id, output_dir)
            elif args.scenario == "full-location-roundtrip":
                evidence = await full_location_roundtrip(
                    client,
                    session_id,
                    args.app_bundle_id,
                    output_dir,
                )
            elif args.scenario == "restore-only":
                evidence = await restore_only(
                    client,
                    session_id,
                    args.app_bundle_id,
                    output_dir,
                )
            elif args.scenario == "map-features":
                evidence = await map_features(client, session_id, output_dir)
            elif args.scenario == "config-picker-cancel":
                evidence = await config_picker_cancel(client, session_id, output_dir)
            elif args.scenario == "final-connection-state":
                evidence = await final_connection_state(
                    client,
                    args.app_bundle_id,
                    output_dir,
                )
            elif args.scenario == "shadowrocket-ui-recovery":
                evidence = await recover_shadowrocket_with_ui(
                    client,
                    args.app_bundle_id,
                    output_dir,
                )
            elif args.scenario == "settings-probe":
                evidence = await probe_location_settings(client, session_id, output_dir)
            else:
                evidence = [await capture(client, session_id, output_dir, "wloc-probe")]
            return {
                "timestamp": int(time.time()),
                "status": status,
                "session_id": session_id,
                "scenario": args.scenario,
                "evidence": evidence,
            }
        finally:
            runner_task.cancel()
            with suppress(asyncio.CancelledError):
                await runner_task


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--runner-bundle-id", required=True)
    parser.add_argument("--app-bundle-id", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--startup-attempts",
        type=int,
        default=2,
        help="retry WebDriverAgent startup before a scenario begins (default: 2)",
    )
    parser.add_argument(
        "--scenario",
        choices=(
            "probe",
            "grant-location",
            "global-probe",
            "location-search-probe",
            "location-toggle-roundtrip",
            "module-check",
            "full-location-roundtrip",
            "restore-only",
            "map-features",
            "config-picker-cancel",
            "final-connection-state",
            "shadowrocket-ui-recovery",
            "settings-probe",
        ),
        default="probe",
    )
    args = parser.parse_args()
    if args.startup_attempts < 1:
        parser.error("--startup-attempts must be at least 1")
    return args


def write_result(output_dir: Path, result: dict) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    result_path = output_dir / "result.json"
    result_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))


def run_with_startup_retries(args: argparse.Namespace, run_once=None) -> dict:
    if run_once is None:
        run_once = run_probe
    for attempt in range(1, args.startup_attempts + 1):
        try:
            return asyncio.run(run_once(args))
        except WdaStartupError as error:
            if attempt == args.startup_attempts:
                raise
            trace(f"startup attempt {attempt}/{args.startup_attempts} failed; retrying: {error}")
    raise AssertionError("startup attempt loop exited unexpectedly")


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir).resolve()
    try:
        result = run_with_startup_retries(args)
        result["succeeded"] = True
        write_result(output_dir, result)
    except Exception as error:
        write_result(
            output_dir,
            {
                "timestamp": int(time.time()),
                "scenario": args.scenario,
                "succeeded": False,
                "error_type": type(error).__name__,
                "error": str(error),
            },
        )
        raise


if __name__ == "__main__":
    main()
