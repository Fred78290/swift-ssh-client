import Foundation
import NIO
import NIOSSH

class SSHCommandSession: SSHSession {
    private let invocation: SSHCommandInvocation
    private let promise: Promise<Void>

    var futureResult: Future<Void> {
        promise.futureResult
    }

    // MARK: - Life Cycle

    init(invocation: SSHCommandInvocation,
         promise: Promise<Void>) {
        self.invocation = invocation
        self.promise = promise
    }

    // MARK: - SSHSession

    func start(in context: SSHSessionContext) {
        let channel = context.channel
        let result = channel.pipeline.addHandlers(
            [
                SSHCommandHandler(
                    invocation: invocation,
                    promise: promise
                ),
            ]
        )
        context.promise.completeWith(result)
    }
}

private class SSHCommandHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let invocation: SSHCommandInvocation
    private let promise: Promise<Void>

    // MARK: - Life Cycle

    init(invocation: SSHCommandInvocation,
         promise: Promise<Void>) {
        self.invocation = invocation
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: invocation.command.command,
            wantReply: invocation.wantsReply
        )
        context
            .channel
            .setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .flatMap {
                context.triggerUserOutboundEvent(execRequest)
            }
            .whenFailure { _ in
                context.close(promise: nil)
            }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        promise.fail(SSHConnectionError.unknown)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as SSHChannelRequestEvent.ExitStatus:
            invocation.onStatus?(SSHCommandStatus(exitStatus: event.exitStatus))
        case let event as ChannelEvent:
            switch event {
            case .inputClosed:
                promise.succeed(())
            case .outputClosed:
                promise.fail(SSHConnectionError.unknown)
            }
        default:
            print("✅", event)
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = channelData.data,
              let data = bytes.readData(length: bytes.readableBytes)
        else {
            fatalError("Unexpected read type")
        }
        switch channelData.type {
        case .channel:
            invocation.onChunk?(.init(channel: .standard, data: data))
            return
        case .stdErr:
            invocation.onChunk?(.init(channel: .error, data: data))
        default:
            fatalError("Unexpected message type")
        }
    }
}
