import XCTest
import UIKit
import WebKit
@testable import OpenClient

final class OpenClientBridgeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OpenClientImageMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        OpenClientImageMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDecodesToolRequest() throws {
        let data = Data(
            """
            {
              "protocol": 1,
              "type": "request",
              "id": "request-1",
              "method": "list_tools",
              "params": { "sessionID": "session-1" }
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(OpenClientBridgeServerMessage.self, from: data)
        XCTAssertEqual(
            message,
            .request(
                OpenClientBridgeRequest(
                    id: "request-1",
                    method: .listTools,
                    params: .object(["sessionID": .string("session-1")])
                )
            )
        )
    }

    func testDiscoveryBuildsEntirePortRangeFromServerHost() {
        let config = OpenCodeServerConfig(baseURL: "http://100.64.0.10:4096")
        let endpoints = OpenClientBridgeEndpointDiscovery.candidateEndpoints(config: config)

        XCTAssertEqual(endpoints.count, 21)
        XCTAssertEqual(endpoints.first?.healthURL.absoluteString, "http://100.64.0.10:4070/openclient/v1/health")
        XCTAssertEqual(endpoints.last?.webSocketURL.absoluteString, "ws://100.64.0.10:4090/openclient/v1/ws")
        XCTAssertEqual(endpoints.first?.openCodePort, 4096)
    }

    func testDeviceRegistryPublishesAndExecutesStatusTool() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let tools = await registry.listTools()
        XCTAssertEqual(
            tools.map(\.id),
            [
                "openclient_device_status",
                "openclient_visual_chart",
                "openclient_visual_html",
                "openclient_visual_map",
            ]
        )

        let result = try await registry.execute(
            toolID: "openclient_device_status",
            arguments: [:],
            context: OpenClientRemoteToolContext(
                jsonValue: .object([
                    "sessionID": .string("session-1"),
                    "messageID": .string("message-1"),
                    "agent": .string("build"),
                    "directory": .string("/tmp/project"),
                    "worktree": .string("/tmp/project"),
                ])
            )
        )
        XCTAssertEqual(result.title, "OpenClient device status")
        XCTAssertTrue(result.output.contains("session-1"))
    }

    func testVisualMapToolValidatesAndReturnsRendererMetadata() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let result = try await registry.execute(
            toolID: OpenClientVisualMapContract.toolID,
            arguments: Self.mapArguments,
            context: try Self.context()
        )

        XCTAssertEqual(result.title, "San Francisco")
        XCTAssertEqual(result.output, "Displayed San Francisco with 1 marker.")
        XCTAssertEqual(result.metadata?["renderer"], .string(OpenClientVisualMapContract.rendererID))
        XCTAssertEqual(result.metadata?["schemaVersion"], .number(1))

        let payloadValue = try XCTUnwrap(result.metadata?["payload"])
        let payloadData = try JSONEncoder().encode(payloadValue)
        let payload = try JSONDecoder().decode(OpenClientVisualMapPayload.self, from: payloadData)
        XCTAssertEqual(payload.center, OpenClientVisualMapCoordinate(latitude: 37.7749, longitude: -122.4194))
        XCTAssertEqual(payload.markers.map(\.id), ["ferry-building"])
        XCTAssertEqual(payload.span, .defaultValue)
    }

    func testVisualMapToolRejectsInvalidCoordinates() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.mapArguments
        arguments["center"] = .object([
            "latitude": .number(91),
            "longitude": .number(-122.4194),
        ])

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualMapContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected invalid coordinates to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments.center")
            )
        }
    }

    func testVisualMapToolRejectsUnknownArguments() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.mapArguments
        arguments["unexpected"] = .bool(true)

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualMapContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected unknown arguments to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments")
            )
        }
    }

    func testVisualMapActivityRestoresPersistedToolPayload() throws {
        let data = Data(
            """
            {
              "id": "part-map",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-map",
              "state": {
                "status": "completed",
                "title": "San Francisco on iPhone",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_map",
                  "arguments": {
                    "schemaVersion": 1,
                    "title": "Unnormalized input",
                    "center": { "latitude": 0, "longitude": 0 }
                  }
                },
                "output": "Displayed San Francisco with 1 marker.",
                "metadata": {
                  "toolID": "openclient_visual_map",
                  "renderer": "openclient.map.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "title": "San Francisco",
                    "center": { "latitude": 37.7749, "longitude": -122.4194 },
                    "span": { "latitudeDelta": 0.08, "longitudeDelta": 0.08 },
                    "markers": [
                      {
                        "id": "ferry-building",
                        "title": "Ferry Building",
                        "coordinate": { "latitude": 37.7955, "longitude": -122.3937 }
                      }
                    ]
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        let activity = try XCTUnwrap(OpenClientVisualMapActivity(part: part))

        XCTAssertEqual(part.state?.input?.clientID, "client-1")
        XCTAssertEqual(part.state?.input?.toolID, OpenClientVisualMapContract.toolID)
        XCTAssertEqual(part.state?.metadata?.renderer, OpenClientVisualMapContract.rendererID)
        XCTAssertEqual(activity.payload.title, "San Francisco")
        XCTAssertEqual(activity.payload.markers.first?.title, "Ferry Building")
        XCTAssertFalse(activity.isRunning)
    }

    func testVisualChartToolValidatesTimeSeriesAndReturnsRendererMetadata() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let result = try await registry.execute(
            toolID: OpenClientVisualChartContract.toolID,
            arguments: Self.chartArguments,
            context: try Self.context()
        )

        XCTAssertEqual(result.title, "Weekly Active Users")
        XCTAssertEqual(result.output, "Displayed a line chart with 3 data points.")
        XCTAssertEqual(result.metadata?["renderer"], .string(OpenClientVisualChartContract.rendererID))

        let payloadValue = try XCTUnwrap(result.metadata?["payload"])
        let payloadData = try JSONEncoder().encode(payloadValue)
        let payload = try JSONDecoder().decode(OpenClientVisualChartPayload.self, from: payloadData)
        XCTAssertEqual(payload.chartType, .line)
        XCTAssertEqual(payload.xAxis.type, .time)
        XCTAssertEqual(payload.pointCount, 3)
    }

    func testVisualChartToolRejectsInvalidTimeValue() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.chartArguments
        guard case .array(var series)? = arguments["series"],
              case .object(var firstSeries) = series[0],
              case .array(var points)? = firstSeries["points"],
              case .object(var firstPoint) = points[0] else {
            return XCTFail("Invalid chart test fixture")
        }
        firstPoint["x"] = .string("next Tuesday")
        points[0] = .object(firstPoint)
        firstSeries["points"] = .array(points)
        series[0] = .object(firstSeries)
        arguments["series"] = .array(series)

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualChartContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected invalid time value to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments.series.points.x")
            )
        }
    }

    func testVisualChartToolRejectsNegativePieValue() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let arguments: [String: OpenClientJSONValue] = [
            "schemaVersion": .number(1),
            "chartType": .string("pie"),
            "xAxis": .object(["type": .string("category")]),
            "series": .array([
                .object([
                    "id": .string("share"),
                    "name": .string("Share"),
                    "points": .array([
                        .object([
                            "id": .string("ios"),
                            "x": .string("iOS"),
                            "y": .number(-1),
                        ]),
                    ]),
                ]),
            ]),
        ]

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualChartContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected negative pie value to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments.series.points.y")
            )
        }
    }

    func testVisualChartActivityRestoresPersistedPayload() throws {
        let data = Data(
            """
            {
              "id": "part-chart",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-chart",
              "state": {
                "status": "completed",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_chart",
                  "arguments": {
                    "schemaVersion": 1,
                    "chartType": "bar",
                    "xAxis": { "type": "category" },
                    "series": [{
                      "id": "draft",
                      "name": "Draft",
                      "points": [{ "id": "draft-a", "x": "A", "y": 1 }]
                    }]
                  }
                },
                "output": "Displayed a donut chart with 2 data points.",
                "metadata": {
                  "toolID": "openclient_visual_chart",
                  "renderer": "openclient.chart.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "chartType": "donut",
                    "title": "Platform Share",
                    "xAxis": { "type": "category" },
                    "yAxis": {},
                    "series": [{
                      "id": "share",
                      "name": "Share",
                      "points": [
                        { "id": "ios", "x": "iOS", "y": 72 },
                        { "id": "macos", "x": "macOS", "y": 28 }
                      ]
                    }]
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        let activity = try XCTUnwrap(OpenClientVisualChartActivity(part: part))

        XCTAssertEqual(part.state?.input?.toolID, OpenClientVisualChartContract.toolID)
        XCTAssertEqual(part.state?.metadata?.renderer, OpenClientVisualChartContract.rendererID)
        XCTAssertEqual(activity.payload.title, "Platform Share")
        XCTAssertEqual(activity.payload.chartType, .donut)
        XCTAssertEqual(activity.payload.pointCount, 2)
        XCTAssertFalse(activity.isRunning)
    }

    func testVisualHTMLToolReturnsSandboxedRendererMetadata() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let result = try await registry.execute(
            toolID: OpenClientVisualHTMLContract.toolID,
            arguments: Self.htmlArguments,
            context: try Self.context()
        )

        XCTAssertEqual(result.title, "Bridge Architecture")
        XCTAssertEqual(result.output, "Displayed the static HTML visual \"Bridge Architecture\".")
        XCTAssertEqual(result.metadata?["renderer"], .string(OpenClientVisualHTMLContract.rendererID))

        let payloadValue = try XCTUnwrap(result.metadata?["payload"])
        let payloadData = try JSONEncoder().encode(payloadValue)
        let payload = try JSONDecoder().decode(OpenClientVisualHTMLPayload.self, from: payloadData)
        XCTAssertEqual(payload.height, 280)
        XCTAssertTrue(payload.html.contains("<svg"))
        XCTAssertEqual(payload.documentID.count, 64)
    }

    func testVisualHTMLToolAllowsLongPages() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.htmlArguments
        arguments["height"] = .number(4_800)

        let result = try await registry.execute(
            toolID: OpenClientVisualHTMLContract.toolID,
            arguments: arguments,
            context: try Self.context()
        )
        let payloadValue = try XCTUnwrap(result.metadata?["payload"])
        let payloadData = try JSONEncoder().encode(payloadValue)
        let payload = try JSONDecoder().decode(OpenClientVisualHTMLPayload.self, from: payloadData)

        XCTAssertEqual(payload.height, 4_800)
    }

    func testVisualHTMLToolRejectsExecutableAndEmbeddedContent() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let unsafeFragments = [
            "<script>alert('no')</script>",
            "<img src='https://example.com/tracker.png'>",
            "<div onclick='alert(1)'>Tap me</div>",
            "<style>@import 'https://example.com/style.css';</style>",
            "<iframe srcdoc='<p>nested</p>'></iframe>",
            "<img/src='https://example.com/tracker.png'>",
            "<svg/onload='alert(1)'></svg>",
            "<svg><image xlink:href='data:image/png;base64,AAAA'></image></svg>",
            "<style>@keyframes pulse { to { opacity: 0 } } .x { animation: pulse 1s infinite; }</style>",
            "<svg><filter id='blur'><feGaussianBlur stdDeviation='50'/></filter></svg>",
            "<div style='background: red'>inline style</div>",
            #"<style>@\6b eyframes pulse { to { opacity: 0 } }</style>"#,
        ]

        for fragment in unsafeFragments {
            var arguments = Self.htmlArguments
            arguments["html"] = .string(fragment)
            do {
                _ = try await registry.execute(
                    toolID: OpenClientVisualHTMLContract.toolID,
                    arguments: arguments,
                    context: try Self.context()
                )
                XCTFail("Expected unsafe HTML to be rejected: \(fragment)")
            } catch {
                XCTAssertEqual(
                    error as? OpenClientBridgeProtocolError,
                    .invalidField("arguments.html")
                )
            }
        }
    }

    func testVisualHTMLToolRejectsExcessiveElementCount() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.htmlArguments
        arguments["html"] = .string(String(repeating: "<span>node</span>", count: 201))

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualHTMLContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected excessive HTML complexity to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments.html")
            )
        }
    }

    func testVisualHTMLActivityRestoresPersistedPayload() throws {
        let data = Data(
            """
            {
              "id": "part-html",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-html",
              "state": {
                "status": "completed",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_html",
                  "arguments": {
                    "schemaVersion": 1,
                    "title": "Draft",
                    "accessibilityLabel": "Draft visual",
                    "html": "<p>Draft</p>",
                    "height": 160
                  }
                },
                "output": "Displayed the static HTML visual.",
                "metadata": {
                  "toolID": "openclient_visual_html",
                  "renderer": "openclient.html.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "title": "Canonical Visual",
                    "accessibilityLabel": "Three connected architecture nodes.",
                    "html": "<div class='nodes'>App → Bridge → OpenCode</div>",
                    "height": 240
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        let activity = try XCTUnwrap(OpenClientVisualHTMLActivity(part: part))

        XCTAssertEqual(activity.payload.title, "Canonical Visual")
        XCTAssertEqual(activity.payload.height, 240)
        XCTAssertEqual(activity.payload.accessibilityLabel, "Three connected architecture nodes.")
        XCTAssertFalse(activity.isRunning)
    }

    func testVisualVideoActivityRestoresDormantResourcePayload() throws {
        let cover = Self.visualPreview(width: 2, height: 1)
        let data = Data(
            """
            {
              "id": "part-video",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-video",
              "state": {
                "status": "completed",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_video",
                  "arguments": {
                    "schemaVersion": 1,
                    "title": "Launch",
                    "filePath": "/Volumes/Media/launch.mp4"
                  }
                },
                "output": "Prepared the video for lazy playback.",
                "metadata": {
                  "toolID": "openclient_visual_video",
                  "renderer": "openclient.video.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "title": "Launch",
                    "resourceID": "abcdefghijklmnopqrstuvwxyzABCDEF",
                    "startPath": "/openclient/v1/video/resources/abcdefghijklmnopqrstuvwxyzABCDEF/stream",
                    "stopPath": "/openclient/v1/video/resources/abcdefghijklmnopqrstuvwxyzABCDEF/stream",
                     "expiresAt": "2026-07-27T18:00:00.000Z",
                     "width": 1920,
                     "height": 1080,
                     "rotation": 0,
                     "duration": 12.5,
                     "cover": {
                       "mimeType": "image/jpeg",
                       "dataURL": "\(cover.dataURL)",
                       "width": 2,
                       "height": 1
                     },
                     "file": {
                      "name": "launch.mp4",
                      "sizeBytes": 42000000,
                      "modifiedAt": "2026-07-27T12:00:00.000Z",
                      "mimeType": "video/mp4"
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        XCTAssertEqual(part.state?.input?.toolID, OpenClientVisualVideoContract.toolID)
        XCTAssertEqual(part.state?.metadata?.renderer, OpenClientVisualVideoContract.rendererID)
        let payloadValue = try XCTUnwrap(part.state?.metadata?.payload)
        let payloadData = try JSONEncoder().encode(payloadValue)
        let decodedPayload = try JSONDecoder().decode(OpenClientVisualVideoPayload.self, from: payloadData)
        _ = try decodedPayload.validated()
        let activity = try XCTUnwrap(OpenClientVisualVideoActivity(part: part))

        XCTAssertEqual(activity.payload.displayTitle, "Launch")
        XCTAssertEqual(activity.payload.file.name, "launch.mp4")
        XCTAssertEqual(activity.payload.file.sizeBytes, 42_000_000)
        XCTAssertFalse(activity.payload.startPath.contains("Volumes"))
        XCTAssertEqual(activity.payload.width, 1920)
        XCTAssertEqual(activity.payload.cover, cover)
        XCTAssertEqual(activity.payload.cover?.data, cover.data)
        XCTAssertEqual(activity.id.sessionID, "session-1")
        XCTAssertEqual(activity.id.messageID, "message-1")
        XCTAssertEqual(activity.id.partID, "part-video")
    }

    func testVisualVideoPayloadUsesRotatedSourceDimensions() throws {
        var payload = Self.videoPayload()
        payload.width = 1080
        payload.height = 1920
        payload.rotation = 90
        payload.duration = 12.5

        let validated = try payload.validated()

        XCTAssertEqual(validated.width, 1080)
        XCTAssertEqual(validated.height, 1920)
        XCTAssertEqual(validated.rotation, 90)
        XCTAssertEqual(validated.duration, 12.5)
        XCTAssertEqual(validated.displayAspectRatio, 1920.0 / 1080.0, accuracy: 0.001)
    }

    @MainActor
    func testVideoPlaybackStoreRetainsControllerForLogicalPart() {
        let payload = Self.videoPayload()
        let activity = OpenClientVisualVideoActivity(payload: payload)
        let store = OpenClientVideoPlaybackStore()

        XCTAssertTrue(store.controller(for: activity) === store.controller(for: activity))
    }

    func testVisualVideoPayloadRejectsResourcePathSubstitution() throws {
        let payload = Self.videoPayload(
            startPath: "/openclient/v1/video/resources/another-resource/stream"
        )

        XCTAssertThrowsError(try payload.validated()) { error in
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("payload.startPath")
            )
        }
    }

    @MainActor
    func testVideoStreamCoordinatorUsesConnectedBridgeEndpoint() async throws {
        let suiteName = "OpenClientBridgeTests.Video.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let transport = RecordingVideoStreamTransport()
        let coordinator = OpenClientVideoStreamCoordinator(
            bridgeStore: store,
            transport: transport
        )
        let payload = Self.videoPayload()

        do {
            _ = try await coordinator.start(payload: payload)
            XCTFail("Expected disconnected playback to fail")
        } catch {
            XCTAssertEqual(error as? OpenClientVideoStreamError, .unavailable)
        }

        let endpoint = OpenClientBridgeEndpoint(
            healthURL: try XCTUnwrap(URL(string: "http://100.64.0.10:4070/openclient/v1/health")),
            webSocketURL: try XCTUnwrap(URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")),
            port: 4070,
            openCodePort: 4096
        )
        store.apply(.connected(endpoint))

        let stream = try await coordinator.start(payload: payload)
        XCTAssertEqual(stream.playlistURL.absoluteString, "http://100.64.0.10:4070/openclient/v1/video/streams/abcdefghijklmnopqrstuvwxyzABCDEF/playlist.m3u8")
        let startedEndpoint = await transport.startedEndpoint
        XCTAssertEqual(startedEndpoint, endpoint)

        await coordinator.stop(stream: stream)
        let stoppedEndpoint = await transport.stoppedEndpoint
        XCTAssertEqual(stoppedEndpoint, endpoint)
    }

    func testVisualImageActivityRestoresPersistedResourcePayload() throws {
        let preview = Self.visualPreview(width: 2, height: 1)
        let data = Data(
            """
            {
              "id": "part-image",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-image",
              "state": {
                "status": "completed",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_image",
                  "arguments": {
                    "schemaVersion": 1,
                    "filePath": "/private/host/path/aurora.png"
                  }
                },
                "output": "Prepared the image for lazy viewing.",
                "metadata": {
                  "toolID": "openclient_visual_image",
                  "renderer": "openclient.image.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "title": "Aurora",
                    "accessibilityLabel": "Green lights over a mountain.",
                    "resourceID": "abcdefghijklmnopqrstuvwxyzABCDEF",
                    "contentPath": "/openclient/v1/image/resources/abcdefghijklmnopqrstuvwxyzABCDEF/content",
                    "expiresAt": "2026-08-27T18:00:00.000Z",
                    "width": 1200,
                    "height": 800,
                    "file": {
                      "name": "aurora.png",
                      "sizeBytes": 2048,
                      "modifiedAt": "2026-07-27T12:00:00.000Z",
                      "mimeType": "image/png"
                    },
                    "preview": {
                      "mimeType": "image/jpeg",
                      "dataURL": "\(preview.dataURL)",
                      "width": 2,
                      "height": 1
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        let activity = try XCTUnwrap(OpenClientVisualImageActivity(part: part))

        XCTAssertEqual(part.state?.input?.toolID, OpenClientVisualImageContract.toolID)
        XCTAssertEqual(part.state?.metadata?.renderer, OpenClientVisualImageContract.rendererID)
        XCTAssertEqual(activity.payload.displayTitle, "Aurora")
        XCTAssertEqual(activity.payload.accessibilityLabel, "Green lights over a mountain.")
        XCTAssertEqual(activity.payload.preview, preview)
        XCTAssertEqual(activity.payload.preview.data, preview.data)
        XCTAssertEqual(activity.id.sessionID, "session-1")
        XCTAssertEqual(activity.id.messageID, "message-1")
        XCTAssertEqual(activity.id.partID, "part-image")
    }

    func testVisualImagePayloadRejectsResourcePathSubstitution() throws {
        let payload = Self.imagePayload(
            contentPath: "/openclient/v1/image/resources/another-resource/content"
        )

        XCTAssertThrowsError(try payload.validated()) { error in
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("payload.contentPath")
            )
        }
    }

    func testVisualImagePayloadRejectsInvalidMetadataConstraints() {
        let cases: [(OpenClientVisualImagePayload, OpenClientBridgeProtocolError)] = [
            (
                Self.imagePayload(declaredSize: OpenClientVisualImageContract.maximumFileBytes + 1),
                .invalidField("payload.file")
            ),
            (
                Self.imagePayload(fileName: "aurora.png", mimeType: "image/jpeg"),
                .invalidField("payload.file")
            ),
            (
                Self.imagePayload(modifiedAt: "not-a-date"),
                .invalidField("payload.file")
            ),
            (
                Self.imagePayload(title: "   "),
                .invalidField("payload.title")
            ),
            (
                Self.imagePayload(accessibilityLabel: String(repeating: "a", count: 501)),
                .invalidField("payload.accessibilityLabel")
            ),
            (
                Self.imagePayload(width: 0),
                .invalidField("payload.dimensions")
            ),
        ]

        for (payload, expectedError) in cases {
            XCTAssertThrowsError(try payload.validated()) { error in
                XCTAssertEqual(error as? OpenClientBridgeProtocolError, expectedError)
            }
        }
    }

    func testVisualPreviewRejectsInvalidOversizeAndMismatchedJPEGData() throws {
        XCTAssertThrowsError(
            try OpenClientVisualPreview(
                mimeType: "image/jpeg",
                dataURL: "data:image/jpeg;base64,not canonical base64",
                width: 1,
                height: 1
            )
        ) { error in
            XCTAssertEqual(error as? OpenClientVisualPreviewError, .invalidDataURL)
        }

        var oversized = Data(repeating: 0, count: OpenClientVisualPreview.maximumDecodedBytes + 1)
        oversized[oversized.startIndex] = 0xff
        oversized[oversized.startIndex + 1] = 0xd8
        oversized[oversized.endIndex - 2] = 0xff
        oversized[oversized.endIndex - 1] = 0xd9
        XCTAssertThrowsError(
            try OpenClientVisualPreview(
                mimeType: "image/jpeg",
                dataURL: OpenClientVisualPreview.dataURLPrefix + oversized.base64EncodedString(),
                width: 1,
                height: 1
            )
        ) { error in
            XCTAssertEqual(error as? OpenClientVisualPreviewError, .exceedsSizeLimit)
        }

        let twoByOneJPEG = Self.jpegData(width: 2, height: 1)
        XCTAssertThrowsError(
            try OpenClientVisualPreview(jpegData: twoByOneJPEG, width: 1, height: 1)
        ) { error in
            XCTAssertEqual(error as? OpenClientVisualPreviewError, .invalidDimensions)
        }
        XCTAssertThrowsError(
            try OpenClientVisualPreview(jpegData: twoByOneJPEG, width: 97, height: 1)
        ) { error in
            XCTAssertEqual(error as? OpenClientVisualPreviewError, .invalidDimensions)
        }
    }

    @MainActor
    func testImageContentCoordinatorUsesConnectedBridgeEndpoint() async throws {
        let suiteName = "OpenClientBridgeTests.Image.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let transport = RecordingImageContentTransport()
        let coordinator = OpenClientImageContentCoordinator(
            bridgeStore: store,
            transport: transport
        )
        let payload = Self.imagePayload()

        do {
            _ = try await coordinator.load(payload: payload)
            XCTFail("Expected disconnected image loading to fail")
        } catch {
            XCTAssertEqual(error as? OpenClientImageContentError, .unavailable)
        }

        let endpoint = Self.bridgeEndpoint()
        store.apply(.connected(endpoint))
        let image = try await coordinator.load(payload: payload)

        XCTAssertEqual(image.width, payload.width)
        XCTAssertEqual(image.height, payload.height)
        let loadedEndpoint = await transport.loadedEndpoint
        XCTAssertEqual(loadedEndpoint, endpoint)
    }

    func testImageContentClientLoadsExactConnectedResourceResponse() async throws {
        let bytes = Self.jpegData(width: 4, height: 3)
        let payload = Self.imagePayload(imageData: bytes, width: 4, height: 3)
        OpenClientImageMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, payload.contentPath)
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.url?.fragment)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/jpeg")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/jpeg",
                        "Content-Length": "\(bytes.count)",
                    ]
                )!,
                bytes
            )
        }

        let client = OpenClientImageContentClient(sessionConfiguration: Self.imageSessionConfiguration())
        let image = try await client.load(payload: payload, endpoint: Self.bridgeEndpoint())

        XCTAssertEqual(image.data, bytes)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
    }

    func testImageContentClientRejectsInvalidResponses() async throws {
        let bytes = Self.jpegData(width: 2, height: 1)
        let payload = Self.imagePayload(imageData: bytes, width: 2, height: 1)
        let endpoint = Self.bridgeEndpoint()

        try await assertImageLoadError(.statusCode(404), payload: payload, endpoint: endpoint) { request in
            Self.imageResponse(request: request, status: 404, contentType: "image/jpeg", contentLength: bytes.count, data: bytes)
        }
        try await assertImageLoadError(
            .invalidContentType(expected: "image/jpeg", actual: "image/png"),
            payload: payload,
            endpoint: endpoint
        ) { request in
            Self.imageResponse(request: request, contentType: "image/png", contentLength: bytes.count, data: bytes)
        }
        try await assertImageLoadError(
            .invalidContentLength(expected: Int64(bytes.count), actual: Int64(bytes.count + 1)),
            payload: payload,
            endpoint: endpoint
        ) { request in
            Self.imageResponse(request: request, contentType: "image/jpeg", contentLength: bytes.count + 1, data: bytes)
        }

        let mismatchedPayload = Self.imagePayload(imageData: bytes, width: 3, height: 2)
        try await assertImageLoadError(
            .dimensionMismatch(expectedWidth: 3, expectedHeight: 2, actualWidth: 2, actualHeight: 1),
            payload: mismatchedPayload,
            endpoint: endpoint
        ) { request in
            Self.imageResponse(request: request, contentType: "image/jpeg", contentLength: bytes.count, data: bytes)
        }

        let maximumPayload = Self.imagePayload(
            imageData: bytes,
            width: 2,
            height: 1,
            declaredSize: OpenClientVisualImageContract.maximumFileBytes
        )
        try await assertImageLoadError(.responseTooLarge, payload: maximumPayload, endpoint: endpoint) { request in
            let oversized = Data(count: Int(OpenClientVisualImageContract.maximumFileBytes) + 1)
            return Self.imageResponse(request: request, contentType: "image/jpeg", contentLength: nil, data: oversized)
        }
    }

    @MainActor
    func testImageLoadingStoreRetainsControllerForLogicalPart() throws {
        let firstActivity = try XCTUnwrap(OpenClientVisualImageActivity(
            part: Self.imagePart(payload: Self.imagePayload(), partID: "part-image")
        ))
        let replacementPayload = Self.imagePayload(resourceID: "0123456789abcdefghijklmnopqrstuv")
        let replacementActivity = try XCTUnwrap(OpenClientVisualImageActivity(
            part: Self.imagePart(payload: replacementPayload, partID: "part-image")
        ))
        let store = OpenClientImageLoadingStore()

        XCTAssertEqual(firstActivity.id, replacementActivity.id)
        XCTAssertTrue(
            store.controller(for: firstActivity) === store.controller(for: replacementActivity)
        )
    }

    @MainActor
    func testWhatsNewImageDemoStartsWithBundledImageLoaded() {
        let activity = OpenClientVisualMediaDemo.imageActivity
        let image = OpenClientVisualMediaDemo.loadedImage
        let controller = OpenClientVisualImageLoadingController(
            id: activity.id,
            payload: activity.payload,
            initialImage: image
        )

        XCTAssertEqual(image.width, activity.payload.width)
        XCTAssertEqual(image.height, activity.payload.height)
        XCTAssertEqual(Int64(image.data.count), activity.payload.file.sizeBytes)
        XCTAssertEqual(controller.phase, .loaded(image))
    }

    func testStaticHTMLDocumentInstallsCSPBeforeVisualFragment() throws {
        let fragment = "<svg aria-label='Safe visual'></svg>"
        let preview = OpenClientStaticHTMLDocument.wrap(fragment: fragment, mode: .preview)
        let detail = OpenClientStaticHTMLDocument.wrap(fragment: fragment, mode: .detail)
        let cspRange = try XCTUnwrap(preview.range(of: "Content-Security-Policy"))
        let fragmentRange = try XCTUnwrap(preview.range(of: fragment))

        XCTAssertLessThan(cspRange.lowerBound, fragmentRange.lowerBound)
        XCTAssertTrue(preview.contains("script-src 'none'"))
        XCTAssertTrue(preview.contains("img-src 'none'"))
        XCTAssertTrue(preview.contains("connect-src 'none'"))
        XCTAssertTrue(preview.contains("frame-src 'none'"))
        XCTAssertTrue(preview.contains("form-action 'none'"))
        XCTAssertTrue(preview.contains("user-scalable=no"))
        XCTAssertTrue(preview.contains("overflow: hidden"))
        XCTAssertFalse(preview.contains("user-select: text !important"))
        XCTAssertTrue(detail.contains("user-scalable=yes"))
        XCTAssertTrue(detail.contains("maximum-scale=5"))
        XCTAssertTrue(detail.contains("overflow: auto"))
        XCTAssertTrue(detail.contains("user-select: text !important"))
        XCTAssertTrue(detail.contains("script-src 'none'"))
        XCTAssertTrue(OpenClientStaticHTMLDocument.contentRules.contains("^https://"))
    }

    @MainActor
    func testStaticHTMLWebViewInteractionModes() {
        let previewCoordinator = OpenClientStaticHTMLCoordinator()
        let preview = OpenClientStaticHTMLWebViewFactory.make(
            coordinator: previewCoordinator,
            mode: .preview
        )
        let detailCoordinator = OpenClientStaticHTMLCoordinator()
        let detail = OpenClientStaticHTMLWebViewFactory.make(
            coordinator: detailCoordinator,
            mode: .detail
        )

        XCTAssertFalse(preview.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(detail.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(preview.allowsBackForwardNavigationGestures)
        XCTAssertFalse(detail.allowsBackForwardNavigationGestures)
        XCTAssertFalse(preview.allowsLinkPreview)
        XCTAssertFalse(detail.allowsLinkPreview)
        XCTAssertFalse(preview.scrollView.isScrollEnabled)
        XCTAssertFalse(preview.scrollView.bounces)
        XCTAssertTrue(detail.scrollView.isScrollEnabled)
        XCTAssertTrue(detail.scrollView.bounces)
        XCTAssertTrue(detail.scrollView.alwaysBounceVertical)
    }

    func testVisualHTMLDocumentIDIsDeterministic() throws {
        let payload = try OpenClientVisualHTMLPayload(
            schemaVersion: 1,
            title: "Stable Visual",
            accessibilityLabel: "A stable visual identifier.",
            html: "<p>Stable</p>",
            height: 200
        ).validated()

        XCTAssertEqual(Set((0 ..< 20).map { _ in payload.documentID }).count, 1)
    }

    @MainActor
    func testStaticHTMLDocumentFinishesSecureWebKitLoad() async throws {
        let payload = try OpenClientVisualHTMLPayload(
            schemaVersion: 1,
            title: "WebKit Probe",
            accessibilityLabel: "A secure HTML loading probe.",
            html: "<style>.probe { color: #e6b757; }</style><div class='probe'>Rendered</div>",
            height: 160
        ).validated()
        let coordinator = OpenClientStaticHTMLCoordinator()
        let webView = OpenClientStaticHTMLWebViewFactory.make(coordinator: coordinator, mode: .detail)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.frame = window.bounds
        host.view.addSubview(webView)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var stages: [String] = []
        var result: String?
        coordinator.didUpdateLoadStage = { stages.append($0) }
        coordinator.didFinishLoad = { result = "finished" }
        coordinator.didFailSecureLoad = { error in
            result = "failed: \(error)"
        }

        coordinator.load(payload: payload, into: webView, mode: .detail)
        for _ in 0 ..< 50 where result == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        withExtendedLifetime(coordinator) {}
        XCTAssertEqual(result, "finished", stages.joined(separator: " -> "))
    }

    @MainActor
    func testBridgeFacadePublishesStatusAndRoutesForceConnect() throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        var forceConnectCount = 0
        let facade = OpenClientBridgeFacade(store: store) {
            forceConnectCount += 1
        }

        XCTAssertEqual(facade.snapshot.statusTitle, "Disconnected")
        XCTAssertEqual(facade.snapshot.toolbarSystemImage, "link.circle")
        XCTAssertFalse(facade.snapshot.showsToolbarButton)

        let endpoint = OpenClientBridgeEndpoint(
            healthURL: try XCTUnwrap(URL(string: "http://100.64.0.10:4070/openclient/v1/health")),
            webSocketURL: try XCTUnwrap(URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")),
            port: 4070,
            openCodePort: 4096
        )
        store.apply(.connected(endpoint))

        XCTAssertEqual(facade.snapshot.statusTitle, "Connected")
        XCTAssertEqual(facade.snapshot.toolbarSystemImage, "link.circle.fill")
        XCTAssertTrue(facade.snapshot.showsToolbarButton)
        XCTAssertEqual(facade.snapshot.endpoint, endpoint.webSocketURL)

        facade.forceConnect()
        XCTAssertEqual(forceConnectCount, 1)
    }

    @MainActor
    func testBridgeCoordinatorRetriesDuringInitialServerBootstrap() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore()
        let client = FlakyOpenClientBridgeConnection()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig(baseURL: "http://100.64.0.10:4096") },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        let initialConnectCount = await client.connectCount
        XCTAssertEqual(initialConnectCount, 0)
        connectionStore.updateConnectionPhase(.loadingWorkspace)
        for _ in 0 ..< 50 {
            if await client.connectCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let connectCount = await client.connectCount
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(store.phase, .connected(port: 4070))
        XCTAssertFalse(connectionStore.isConnected)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testBridgeCoordinatorDoesNotConnectForResolvedV2Profile() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore()
        let client = FlakyOpenClientBridgeConnection()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig(baseURL: "http://100.64.0.10:4097", apiPreference: .v2) },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        connectionStore.resolveAPIProfile(.v2)
        connectionStore.updateConnectionPhase(.preparingInterface)
        try await Task.sleep(for: .milliseconds(50))

        let connectCount = await client.connectCount
        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(store.phase, .idle)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testBridgeCoordinatorAutomaticallyRetriesFailedDiscovery() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore(backendMode: .server, isConnected: true)
        let client = FlakyOpenClientBridgeConnection()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig(baseURL: "http://100.64.0.10:4096") },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        for _ in 0 ..< 50 {
            if await client.connectCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let connectCount = await client.connectCount
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(store.phase, .connected(port: 4070))
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testBridgeCoordinatorAutomaticallyReconnectsAfterTransportDisconnects() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore(backendMode: .server, isConnected: true)
        let client = DisconnectingOpenClientBridgeConnection()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig(baseURL: "http://100.64.0.10:4096") },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        for _ in 0 ..< 50 {
            if await client.connectCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let connectCount = await client.connectCount
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(store.phase, .connected(port: 4070))
        withExtendedLifetime(coordinator) {}
    }

    private static let mapArguments: [String: OpenClientJSONValue] = [
        "schemaVersion": .number(1),
        "title": .string("San Francisco"),
        "center": .object([
            "latitude": .number(37.7749),
            "longitude": .number(-122.4194),
        ]),
        "markers": .array([
            .object([
                "id": .string("ferry-building"),
                "title": .string("Ferry Building"),
                "subtitle": .string("Historic waterfront marketplace"),
                "coordinate": .object([
                    "latitude": .number(37.7955),
                    "longitude": .number(-122.3937),
                ]),
            ]),
        ]),
    ]

    private static let chartArguments: [String: OpenClientJSONValue] = [
        "schemaVersion": .number(1),
        "chartType": .string("line"),
        "title": .string("Weekly Active Users"),
        "xAxis": .object([
            "type": .string("time"),
            "title": .string("Week"),
        ]),
        "yAxis": .object([
            "title": .string("Users"),
        ]),
        "series": .array([
            .object([
                "id": .string("users"),
                "name": .string("Users"),
                "points": .array([
                    .object([
                        "id": .string("week-1"),
                        "x": .string("2026-07-06T00:00:00Z"),
                        "y": .number(120),
                    ]),
                    .object([
                        "id": .string("week-2"),
                        "x": .string("2026-07-13T00:00:00Z"),
                        "y": .number(168),
                    ]),
                    .object([
                        "id": .string("week-3"),
                        "x": .string("2026-07-20T00:00:00Z"),
                        "y": .number(214),
                    ]),
                ]),
            ]),
        ]),
    ]

    private static let htmlArguments: [String: OpenClientJSONValue] = [
        "schemaVersion": .number(1),
        "title": .string("Bridge Architecture"),
        "accessibilityLabel": .string("Three connected nodes labeled OpenClient, Bridge, and OpenCode."),
        "height": .number(280),
        "html": .string(
            """
            <style>
            .diagram { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; padding: 20px; }
            .node { padding: 16px; border: 2px solid #ff9f0a; border-radius: 14px; text-align: center; }
            </style>
            <svg viewBox="0 0 600 180" role="img" aria-label="OpenClient bridge architecture">
              <rect x="20" y="50" width="150" height="80" rx="16" fill="#ff9f0a" opacity=".18" />
              <rect x="225" y="50" width="150" height="80" rx="16" fill="#5e5ce6" opacity=".18" />
              <rect x="430" y="50" width="150" height="80" rx="16" fill="#30d158" opacity=".18" />
              <text x="95" y="96" text-anchor="middle">OpenClient</text>
              <text x="300" y="96" text-anchor="middle">Bridge</text>
              <text x="505" y="96" text-anchor="middle">OpenCode</text>
            </svg>
            """
        ),
    ]

    private static func context() throws -> OpenClientRemoteToolContext {
        try OpenClientRemoteToolContext(
            jsonValue: .object([
                "sessionID": .string("session-1"),
                "messageID": .string("message-1"),
                "agent": .string("build"),
                "directory": .string("/tmp/project"),
                "worktree": .string("/tmp/project"),
            ])
        )
    }

    private static func videoPayload(startPath: String? = nil) -> OpenClientVisualVideoPayload {
        let resourceID = "abcdefghijklmnopqrstuvwxyzABCDEF"
        let expectedPath = "/openclient/v1/video/resources/\(resourceID)/stream"
        return OpenClientVisualVideoPayload(
            schemaVersion: 1,
            title: "Launch",
            resourceID: resourceID,
            startPath: startPath ?? expectedPath,
            stopPath: expectedPath,
            expiresAt: "2026-07-27T18:00:00.000Z",
            file: OpenClientVisualVideoFile(
                name: "launch.mp4",
                sizeBytes: 42_000_000,
                modifiedAt: "2026-07-27T12:00:00.000Z",
                mimeType: "video/mp4"
            ),
            width: 1920,
            height: 1080,
            rotation: 0,
            duration: 12.5,
            cover: visualPreview(width: 2, height: 1)
        )
    }

    private static func imagePayload(
        resourceID: String = "abcdefghijklmnopqrstuvwxyzABCDEF",
        contentPath: String? = nil,
        imageData: Data? = nil,
        width: Int = 2,
        height: Int = 1,
        declaredSize: Int64? = nil,
        title: String? = "Aurora",
        accessibilityLabel: String? = "Green lights over a mountain.",
        fileName: String = "aurora.jpg",
        modifiedAt: String = "2026-07-27T12:00:00.000Z",
        mimeType: String = "image/jpeg"
    ) -> OpenClientVisualImagePayload {
        let fixtureWidth = max(1, width)
        let fixtureHeight = max(1, height)
        let data = imageData ?? jpegData(width: fixtureWidth, height: fixtureHeight)
        return OpenClientVisualImagePayload(
            schemaVersion: OpenClientVisualImageContract.schemaVersion,
            title: title,
            accessibilityLabel: accessibilityLabel,
            resourceID: resourceID,
            contentPath: contentPath ?? "/openclient/v1/image/resources/\(resourceID)/content",
            expiresAt: "2026-08-27T18:00:00.000Z",
            width: width,
            height: height,
            file: OpenClientVisualImageFile(
                name: fileName,
                sizeBytes: declaredSize ?? Int64(data.count),
                modifiedAt: modifiedAt,
                mimeType: mimeType
            ),
            preview: visualPreview(width: min(fixtureWidth, 96), height: min(fixtureHeight, 96))
        )
    }

    private static func visualPreview(width: Int, height: Int) -> OpenClientVisualPreview {
        try! OpenClientVisualPreview(
            jpegData: jpegData(width: width, height: height),
            width: width,
            height: height
        )
    }

    private static func imagePart(payload: OpenClientVisualImagePayload, partID: String) throws -> OpenCodePart {
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSON = try XCTUnwrap(String(data: payloadData, encoding: .utf8))
        return try JSONDecoder().decode(
            OpenCodePart.self,
            from: Data(
                """
                {
                  "id": "\(partID)",
                  "messageID": "message-1",
                  "sessionID": "session-1",
                  "type": "tool",
                  "tool": "openclient_execute_tool",
                  "callID": "call-image",
                  "state": {
                    "status": "completed",
                    "input": { "tool_id": "openclient_visual_image" },
                    "metadata": {
                      "renderer": "openclient.image.v1",
                      "payload": \(payloadJSON)
                    }
                  }
                }
                """.utf8
            )
        )
    }

    private static func jpegData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
    }

    private static func bridgeEndpoint() -> OpenClientBridgeEndpoint {
        OpenClientBridgeEndpoint(
            healthURL: URL(string: "http://100.64.0.10:4070/openclient/v1/health")!,
            webSocketURL: URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")!,
            port: 4070,
            openCodePort: 4096
        )
    }

    private static func imageSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenClientImageMockURLProtocol.self]
        return configuration
    }

    private static func imageResponse(
        request: URLRequest,
        status: Int = 200,
        contentType: String,
        contentLength: Int?,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": contentType]
        if let contentLength {
            headers["Content-Length"] = "\(contentLength)"
        }
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!,
            data
        )
    }

    private func assertImageLoadError(
        _ expectedError: OpenClientImageContentError,
        payload: OpenClientVisualImagePayload,
        endpoint: OpenClientBridgeEndpoint,
        response: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) async throws {
        OpenClientImageMockURLProtocol.requestHandler = response
        let client = OpenClientImageContentClient(sessionConfiguration: Self.imageSessionConfiguration())
        do {
            _ = try await client.load(payload: payload, endpoint: endpoint)
            XCTFail("Expected image loading to fail with \(expectedError)")
        } catch {
            XCTAssertEqual(error as? OpenClientImageContentError, expectedError)
        }
    }
}

private actor RecordingVideoStreamTransport: OpenClientVideoStreamTransport {
    private(set) var startedEndpoint: OpenClientBridgeEndpoint?
    private(set) var stoppedEndpoint: OpenClientBridgeEndpoint?

    func start(
        payload: OpenClientVisualVideoPayload,
        endpoint: OpenClientBridgeEndpoint
    ) async throws -> OpenClientVideoStream {
        startedEndpoint = endpoint
        return OpenClientVideoStream(
            id: payload.resourceID,
            playlistURL: URL(string: "http://100.64.0.10:4070/openclient/v1/video/streams/\(payload.resourceID)/playlist.m3u8")!,
            stopPath: "/openclient/v1/video/streams/\(payload.resourceID)"
        )
    }

    func stop(
        stream: OpenClientVideoStream,
        endpoint: OpenClientBridgeEndpoint
    ) async throws {
        stoppedEndpoint = endpoint
    }
}

private actor RecordingImageContentTransport: OpenClientImageContentTransport {
    private(set) var loadedEndpoint: OpenClientBridgeEndpoint?

    func load(
        payload: OpenClientVisualImagePayload,
        endpoint: OpenClientBridgeEndpoint
    ) async throws -> OpenClientLoadedImage {
        loadedEndpoint = endpoint
        return OpenClientLoadedImage(
            data: payload.preview.data,
            platformImage: payload.preview.platformImage,
            width: payload.width,
            height: payload.height
        )
    }
}

private final class OpenClientImageMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: OpenClientImageContentError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor FlakyOpenClientBridgeConnection: OpenClientBridgeConnecting {
    private(set) var connectCount = 0

    func connect(
        config: OpenCodeServerConfig,
        registration: OpenClientBridgeRegistration,
        initialSessionID: String?,
        eventHandler: @escaping @Sendable (OpenClientBridgeClientEvent) -> Void
    ) async throws {
        connectCount += 1
        if connectCount == 1 {
            throw OpenClientBridgeDiscoveryError.notFound
        }
        let endpoint = OpenClientBridgeEndpoint(
            healthURL: URL(string: "http://100.64.0.10:4070/openclient/v1/health")!,
            webSocketURL: URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")!,
            port: 4070,
            openCodePort: 4096
        )
        eventHandler(.connected(endpoint))
    }

    func updateSession(_ sessionID: String?) async {}

    func disconnect() async {}
}

private actor DisconnectingOpenClientBridgeConnection: OpenClientBridgeConnecting {
    private(set) var connectCount = 0

    func connect(
        config: OpenCodeServerConfig,
        registration: OpenClientBridgeRegistration,
        initialSessionID: String?,
        eventHandler: @escaping @Sendable (OpenClientBridgeClientEvent) -> Void
    ) async throws {
        connectCount += 1
        let endpoint = OpenClientBridgeEndpoint(
            healthURL: URL(string: "http://100.64.0.10:4070/openclient/v1/health")!,
            webSocketURL: URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")!,
            port: 4070,
            openCodePort: 4096
        )
        eventHandler(.connected(endpoint))
        if connectCount == 1 {
            Task {
                try? await Task.sleep(for: .milliseconds(5))
                eventHandler(.disconnected("Connection lost"))
            }
        }
    }

    func updateSession(_ sessionID: String?) async {}

    func disconnect() async {}
}
