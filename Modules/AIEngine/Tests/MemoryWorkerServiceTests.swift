@testable import AIEngine
import Foundation
import XCTest

private final class MemoryWorkerURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.requestHandler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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

    static func install(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        requestHandler = handler
        lock.unlock()
        URLProtocol.registerClass(Self.self)
    }

    static func uninstall() {
        lock.lock()
        requestHandler = nil
        lock.unlock()
        URLProtocol.unregisterClass(Self.self)
    }
}

private extension URLRequest {
    func bodyDataForTesting() -> Data? {
        if let httpBody {
            return httpBody
        }

        guard let stream = httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                return nil
            }
            if bytesRead == 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return data
    }
}

final class MemoryWorkerServiceTests: XCTestCase {
    private let placeholderMemoryWorkerEndpoint = "https://memory.example.com"

    override func tearDown() {
        MemoryWorkerURLProtocol.uninstall()
        super.tearDown()
    }

    func testQueryMemories_usesSignedAuthAndParsesItems() async throws {
        let requestObserved = expectation(description: "query request observed")

        MemoryWorkerURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://memory.example.com/api/memories/query")
            XCTAssertEqual(request.httpMethod, "POST")

            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Auth-Timestamp"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Auth-Nonce"))
            let signature = request.value(forHTTPHeaderField: "X-Auth-Signature") ?? ""
            XCTAssertEqual(signature.count, 64)

            let body = try XCTUnwrap(request.bodyDataForTesting())
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(object["scope"] as? String)
                        XCTAssertEqual(object["q"] as? String, "concise")
            XCTAssertEqual(object["limit"] as? Int, 5)
            requestObserved.fulfill()

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {
                  "item": null,
                  "items": [
                    { "id": 101, "content": "User prefers concise Chinese responses." }
                  ],
                  "count": 1,
                  "limit": 5,
                  "filters": {}
                }
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: placeholderMemoryWorkerEndpoint,
                authMode: .signed,
                secret: "demo-pass",
                scope: "user",
                queryLimit: 5
            )
        )

        let items = try await service.queryMemories(q: "concise")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, 101)
        XCTAssertEqual(items.first?.content, "User prefers concise Chinese responses.")

        await fulfillment(of: [requestObserved], timeout: 1.0)
    }

    func testCreateMemory_usesBearerTokenAndReturnsItem() async throws {
        let requestObserved = expectation(description: "create request observed")

        MemoryWorkerURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://memory.example.com/api/memories")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer demo-bearer")

            let body = try XCTUnwrap(request.bodyDataForTesting())
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["scope"] as? String, "user")
                        XCTAssertEqual(object["content"] as? String, "User likes pomodoro mode")
            XCTAssertEqual(object["horizon"] as? String, "daily")
            requestObserved.fulfill()

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {
                  "item": {
                    "id": 202,
                    "content": "User likes pomodoro mode"
                  }
                }
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: placeholderMemoryWorkerEndpoint,
                authMode: .bearer,
                secret: "demo-bearer",
                scope: "user",
            )
        )

        let item = try await service.createMemory(content: "User likes pomodoro mode")
        XCTAssertEqual(item.id, 202)
        XCTAssertEqual(item.content, "User likes pomodoro mode")

        await fulfillment(of: [requestObserved], timeout: 1.0)
    }

    func testCreateMemory_acceptsFlatJSONWithStringId() async throws {
        MemoryWorkerURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {"id":"99","content":"Flat body shape"}
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com",
                authMode: .signed,
                secret: "p",
            )
        )

        let item = try await service.createMemory(content: "Flat body shape")
        XCTAssertEqual(item.id, 99)
        XCTAssertEqual(item.content, "Flat body shape")
    }

    func testCreateMemory_acceptsDataWrappedItem() async throws {
        MemoryWorkerURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {"data":{"id":7,"content":"Wrapped"}}
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com",
                authMode: .bearer,
                secret: "t",
            )
        )

        let item = try await service.createMemory(content: "Wrapped")
        XCTAssertEqual(item.id, 7)
        XCTAssertEqual(item.content, "Wrapped")
    }

    func testCreateMemory_acceptsOkBooleanWithoutNestedItem() async throws {
        MemoryWorkerURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(#"{"ok":true,"id":42}"#.utf8)
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com",
                authMode: .signed,
                secret: "p",
            )
        )

        let item = try await service.createMemory(content: "用户喜欢测试")
        XCTAssertEqual(item.id, 42)
        XCTAssertEqual(item.content, "用户喜欢测试")
    }

    func testCreateMemory_emptyBodyUsesRequestContent() async throws {
        MemoryWorkerURLProtocol.install { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com",
                authMode: .signed,
                secret: "p",
            )
        )

        let item = try await service.createMemory(content: "No JSON body")
        XCTAssertNil(item.id)
        XCTAssertEqual(item.content, "No JSON body")
    }

    func testQueryMemories_acceptsFullQueryEndpointAsBase() async throws {
        let requestObserved = expectation(description: "query request observed for full endpoint")

        MemoryWorkerURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://memory.example.com/api/memories/query")
            requestObserved.fulfill()

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                {
                  "item": null,
                  "items": [],
                  "count": 0,
                  "limit": 5,
                  "filters": {}
                }
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: "https://memory.example.com/api/memories/query",
                authMode: .signed,
                secret: "demo-pass",
                scope: "user",
                queryLimit: 5
            )
        )

        _ = try await service.queryMemories(q: "test")
        await fulfillment(of: [requestObserved], timeout: 1.0)
    }

    func testCreateMemory_sendsTargetAndCategoryFields() async throws {
        let requestObserved = expectation(description: "create with pi model fields observed")

        MemoryWorkerURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://memory.example.com/api/memories")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(request.bodyDataForTesting())
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["target"] as? String, "user")
            XCTAssertEqual(object["category"] as? String, "preference")
            XCTAssertEqual(object["failure_reason"] as? String, "wrong flag")
            XCTAssertEqual((object["metadata"] as? [String: Any])?["importance"] as? String, "2")
            requestObserved.fulfill()

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                { "item": { "id": 7, "content": "prefer concise", "target": "user", "category": "preference" } }
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: placeholderMemoryWorkerEndpoint,
                authMode: .signed,
                secret: "demo-pass",
                scope: "user",
            )
        )

        let item = try await service.createMemory(
            content: "prefer concise",
            target: "user",
            category: "preference",
            failureReason: "wrong flag",
            importance: 2
        )
        XCTAssertEqual(item.id, 7)
        XCTAssertEqual(item.target, "user")
        XCTAssertEqual(item.category, "preference")
        await fulfillment(of: [requestObserved], timeout: 1.0)
    }

    func testUpdateMemory_sendsPatchAndOmitsNilFields() async throws {
        let requestObserved = expectation(description: "patch request observed")

        MemoryWorkerURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://memory.example.com/api/memories/12")
            XCTAssertEqual(request.httpMethod, "PATCH")

            let body = try XCTUnwrap(request.bodyDataForTesting())
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["content"] as? String, "updated content")
            XCTAssertEqual(object["category"] as? String, "preference")
            // nil 字段不应出现，避免误清服务端分类
            XCTAssertNil(object["target"])
            XCTAssertNil(object["tags"])
            XCTAssertNil(object["failure_reason"])
            requestObserved.fulfill()

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = Data(
                """
                { "item": { "id": 12, "content": "updated content", "category": "preference" } }
                """.utf8
            )
            return (response, payload)
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: placeholderMemoryWorkerEndpoint,
                authMode: .signed,
                secret: "demo-pass",
                scope: "user",
            )
        )

        let item = try await service.updateMemory(id: 12, content: "updated content", category: "preference")
        XCTAssertEqual(item?.id, 12)
        XCTAssertEqual(item?.category, "preference")
        await fulfillment(of: [requestObserved], timeout: 1.0)
    }

    func testDeleteMemory_returnsTrueOn200AndFalseOn404() async throws {
        var statuses: [Int] = []
        let requestObserved = expectation(description: "delete requests observed")
        requestObserved.expectedFulfillmentCount = 2

        MemoryWorkerURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statuses.removeFirst(),
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            requestObserved.fulfill()
            return (response, Data("{\"deleted\": true}".utf8))
        }

        let service = MemoryWorkerService(
            config: MemoryWorkerConfig(
                enabled: true,
                endpoint: placeholderMemoryWorkerEndpoint,
                authMode: .signed,
                secret: "demo-pass",
                scope: "user",
            )
        )

        statuses = [200]
        let deleted = try await service.deleteMemory(id: 12)
        XCTAssertTrue(deleted)

        statuses = [404]
        let missing = try await service.deleteMemory(id: 12)
        XCTAssertFalse(missing)

        await fulfillment(of: [requestObserved], timeout: 1.0)
    }

    func testItemDecoding_parsesPiModelFieldsLoosely() throws {
        let payload = Data(
            """
            {
              "id": "42",
              "content": "prefer concise",
              "target": "user",
              "category": "preference",
              "metadata": { "importance": 0.9, "source": "chat" }
            }
            """.utf8
        )

        let item = try JSONDecoder().decode(MemoryWorkerItem.self, from: payload)
        XCTAssertEqual(item.id, 42)
        XCTAssertEqual(item.target, "user")
        XCTAssertEqual(item.category, "preference")
        XCTAssertEqual(item.importance, 1)
    }

    func testCategoryMapping_roundTripsPiVocabulary() {
        XCTAssertEqual(MemoryWorkerService.remoteTargetAndCategory(for: .preference).category, "preference")
        XCTAssertEqual(MemoryWorkerService.remoteTargetAndCategory(for: .preference).target, "user")
        XCTAssertEqual(MemoryWorkerService.remoteTargetAndCategory(for: .fact).category, "insight")
        XCTAssertEqual(MemoryWorkerService.remoteTargetAndCategory(for: .fact).target, "user")
        XCTAssertEqual(MemoryWorkerService.remoteTargetAndCategory(for: .event).target, "memory")

        XCTAssertEqual(MemoryWorkerService.localCategory(fromRemoteCategory: "preference"), .preference)
        XCTAssertEqual(MemoryWorkerService.localCategory(fromRemoteCategory: "event"), .event)
        XCTAssertEqual(MemoryWorkerService.localCategory(fromRemoteCategory: "insight"), .fact)
        XCTAssertEqual(MemoryWorkerService.localCategory(fromRemoteCategory: nil), .fact)
    }
}
