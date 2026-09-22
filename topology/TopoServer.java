import io.netty.bootstrap.Bootstrap;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.nio.NioIoHandler;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.handler.codec.http.*;
import io.netty.handler.codec.http2.*;
import io.netty.util.CharsetUtil;
import io.netty.util.concurrent.EventExecutor;
import io.netty.util.ReferenceCountUtil;
import jdk.jfr.*;

/**
 * Topology tracing launcher. One pipeline per workload; every worker event loop carries a
 * self-renewing tail task that commits a netty.IterationEnd JFR event at the end of each iteration.
 *
 * usage: TopoServer <pipeline> <port> <loops> [backPort]
 */
public final class TopoServer {

    @Name("netty.IterationEnd")
    @Label("Event loop iteration end")
    @Category({"Netty", "Topology"})
    @StackTrace(false)
    @Enabled(true)
    @Registered(true)
    public static final class IterationEnd extends Event {
        @Label("channelRead calls since previous marker")
        public int reads;
    }

    /** per-event-loop-thread channelRead counter, read and reset by the tail task. */
    private static final ThreadLocal<long[]> READS = ThreadLocal.withInitial(() -> new long[1]);

    @ChannelHandler.Sharable
    static final class ReadCounter extends ChannelInboundHandlerAdapter {
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            READS.get()[0]++;
            ctx.fireChannelRead(msg);
        }
    }
    private static final ReadCounter READ_COUNTER = new ReadCounter();

    /** Self-renewing end-of-iteration marker. Re-arms through execute() so the tail drain terminates. */
    static final class IterationMarker implements Runnable {
        private final SingleThreadEventLoop loop;
        private long last;
        IterationMarker(SingleThreadEventLoop loop) { this.loop = loop; }
        void arm() { loop.execute(() -> loop.executeAfterEventLoopIteration(this)); }
        @Override public void run() {
            long[] c = READS.get();
            IterationEnd e = new IterationEnd();
            e.reads = (int) (c[0] - last);
            last = c[0];
            e.commit();
            arm();
        }
    }

    public static void main(String[] args) throws Exception {
        String pipeline = args[0];
        int port = Integer.parseInt(args[1]);
        int loops = Integer.parseInt(args[2]);
        int backPort = args.length > 3 ? Integer.parseInt(args[3]) : 0;

        EventLoopGroup boss = new MultiThreadIoEventLoopGroup(1, NioIoHandler.newFactory());
        EventLoopGroup workers = new MultiThreadIoEventLoopGroup(loops, NioIoHandler.newFactory());
        // separate outbound group for the proxy2 variant
        EventLoopGroup outbound = "proxy2".equals(pipeline)
                ? new MultiThreadIoEventLoopGroup(loops, NioIoHandler.newFactory()) : null;

        ServerBootstrap b = new ServerBootstrap();
        b.group(boss, workers).channel(NioServerSocketChannel.class)
         .childOption(ChannelOption.TCP_NODELAY, true);
        int snd = Integer.getInteger("topo.sndbuf", 0);
        if (snd > 0) { b.childOption(ChannelOption.SO_SNDBUF, snd); }
        b
         .childHandler(initializer(pipeline, backPort, outbound));
        if (pipeline.startsWith("proxy")) {
            b.childOption(ChannelOption.AUTO_READ, false);
        }
        Channel ch = b.bind(port).sync().channel();

        int armed = 0;
        if (Boolean.parseBoolean(System.getProperty("topo.markers", "true"))) {
            armed = armMarkers(workers);
            if (outbound != null) {
                armed += armMarkers(outbound);
            }
        }
        System.out.println("READY " + pipeline + " port=" + port + " loops=" + loops
                + " markers=" + armed + " pid=" + ProcessHandle.current().pid());
        System.out.flush();
        ch.closeFuture().sync();
    }

    private static int armMarkers(EventLoopGroup group) {
        int n = 0;
        for (EventExecutor ee : group) {
            final SingleThreadEventLoop loop = (SingleThreadEventLoop) ee;
            loop.execute(() -> loop.executeAfterEventLoopIteration(new IterationMarker(loop)));
            n++;
        }
        return n;
    }

    private static ChannelHandler initializer(String p, int backPort, EventLoopGroup outbound) {
        switch (p) {
            case "h1snoop":  // W1
                return new ChannelInitializer<SocketChannel>() {
                    @Override protected void initChannel(SocketChannel ch) {
                        ch.pipeline().addLast(READ_COUNTER)
                          .addLast(new HttpRequestDecoder())
                          .addLast(new HttpResponseEncoder())
                          .addLast(new io.netty.example.http.snoop.HttpSnoopServerHandler());
                    }
                };
            case "h2hello":  // W2
                return new ChannelInitializer<SocketChannel>() {
                    @Override protected void initChannel(SocketChannel ch) {
                        ch.pipeline().addLast(READ_COUNTER);
                        ch.pipeline().addLast(Http2FrameCodecBuilder.forServer().build());
                        ch.pipeline().addLast(new Http2MultiplexHandler(new ChannelInitializer<Channel>() {
                            @Override protected void initChannel(Channel c) {
                                c.pipeline().addLast(new H2Echo(0));
                            }
                        }));
                    }
                };
            case "h2echo":   // W3: echo the request body back (large response, small client window)
                return new ChannelInitializer<SocketChannel>() {
                    @Override protected void initChannel(SocketChannel ch) {
                        ch.pipeline().addLast(READ_COUNTER);
                        ch.pipeline().addLast(Http2FrameCodecBuilder.forServer().build());
                        ch.pipeline().addLast(new Http2MultiplexHandler(new ChannelInitializer<Channel>() {
                            @Override protected void initChannel(Channel c) {
                                c.pipeline().addLast(new H2Echo(1));
                            }
                        }));
                    }
                };
            case "h1echo":   // W4: chunked echo of the POST body, for slow readers
                return new ChannelInitializer<SocketChannel>() {
                    @Override protected void initChannel(SocketChannel ch) {
                        ch.pipeline().addLast(READ_COUNTER)
                          .addLast(new HttpServerCodec())
                          .addLast(new H1ChunkEcho());
                    }
                };
            case "h1agg":    // W5: aggregate a 256 KiB body, reply small
                return new ChannelInitializer<SocketChannel>() {
                    @Override protected void initChannel(SocketChannel ch) {
                        ch.pipeline().addLast(READ_COUNTER)
                          .addLast(new HttpServerCodec())
                          .addLast(new HttpObjectAggregator(1024 * 1024))
                          .addLast(new H1AggOk());
                    }
                };
            case "proxy":    // W6a: outbound on the inbound channel's own loop
            case "proxy2":   // W6b: outbound on a separate group
                return new ChannelInitializer<SocketChannel>() {
                    @Override protected void initChannel(SocketChannel ch) {
                        ch.pipeline().addLast(READ_COUNTER)
                          .addLast(new ProxyFront(backPort, outbound));
                    }
                };
            default: throw new IllegalArgumentException(p);
        }
    }

    // ---- HTTP/2 stream handler: mode 0 = small hello, mode 1 = echo the body back ----
    static final class H2Echo extends ChannelDuplexHandler {
        private final int mode;
        private boolean headersSent;
        H2Echo(int mode) { this.mode = mode; }
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            if (msg instanceof Http2HeadersFrame) {
                Http2HeadersFrame h = (Http2HeadersFrame) msg;
                if (!headersSent) {
                    headersSent = true;
                    Http2Headers r = new DefaultHttp2Headers().status("200");
                    ctx.write(new DefaultHttp2HeadersFrame(r, false));
                }
                if (h.isEndStream()) { endStream(ctx); }
            } else if (msg instanceof Http2DataFrame) {
                Http2DataFrame d = (Http2DataFrame) msg;
                if (mode == 1) {
                    // echo the payload back: the buffer stays alive in the remote flow controller
                    ctx.write(new DefaultHttp2DataFrame(d.content().retain(), false));
                }
                boolean end = d.isEndStream();
                ReferenceCountUtil.release(d);
                if (end) { endStream(ctx); }
            } else {
                ReferenceCountUtil.release(msg);
            }
        }
        private void endStream(ChannelHandlerContext ctx) {
            if (mode == 0) {
                ByteBuf body = ctx.alloc().buffer(11).writeBytes("Hello World".getBytes(CharsetUtil.US_ASCII));
                ctx.writeAndFlush(new DefaultHttp2DataFrame(body, true));
            } else {
                ctx.writeAndFlush(new DefaultHttp2DataFrame(Unpooled.EMPTY_BUFFER, true));
            }
        }
        @Override public void channelReadComplete(ChannelHandlerContext ctx) { ctx.flush(); }
    }

    // ---- HTTP/1.1 chunked echo ----
    static final class H1ChunkEcho extends ChannelInboundHandlerAdapter {
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            if (msg instanceof HttpRequest) {
                HttpResponse r = new DefaultHttpResponse(HttpVersion.HTTP_1_1, HttpResponseStatus.OK);
                r.headers().set(HttpHeaderNames.TRANSFER_ENCODING, HttpHeaderValues.CHUNKED);
                r.headers().set(HttpHeaderNames.CONTENT_TYPE, "application/octet-stream");
                ctx.write(r);
            }
            if (msg instanceof LastHttpContent) {
                ByteBuf c = ((LastHttpContent) msg).content();
                if (c.isReadable()) {
                    ctx.write(new DefaultHttpContent(c.retain()));
                }
                ReferenceCountUtil.release(msg);
                ctx.writeAndFlush(LastHttpContent.EMPTY_LAST_CONTENT);
            } else if (msg instanceof HttpContent) {
                ctx.write(new DefaultHttpContent(((HttpContent) msg).content().retain()));
                ReferenceCountUtil.release(msg);
            }
        }
        @Override public void channelReadComplete(ChannelHandlerContext ctx) { ctx.flush(); }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable t) { ctx.close(); }
    }

    // ---- HTTP/1.1 aggregate then small OK ----
    static final class H1AggOk extends SimpleChannelInboundHandler<FullHttpRequest> {
        private static final byte[] OK = "OK".getBytes(CharsetUtil.US_ASCII);
        @Override protected void channelRead0(ChannelHandlerContext ctx, FullHttpRequest req) {
            ByteBuf body = ctx.alloc().buffer(OK.length).writeBytes(OK);
            FullHttpResponse r = new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, HttpResponseStatus.OK, body);
            r.headers().setInt(HttpHeaderNames.CONTENT_LENGTH, body.readableBytes());
            ctx.writeAndFlush(r);
        }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable t) { ctx.close(); }
    }

    // ---- TCP proxy front end (HexDumpProxy without the LoggingHandler) ----
    static final class ProxyFront extends ChannelInboundHandlerAdapter {
        private final int backPort;
        private final EventLoopGroup outboundGroup;
        private volatile Channel out;
        ProxyFront(int backPort, EventLoopGroup outboundGroup) {
            this.backPort = backPort; this.outboundGroup = outboundGroup;
        }
        @Override public void channelActive(ChannelHandlerContext ctx) {
            final Channel in = ctx.channel();
            Bootstrap b = new Bootstrap();
            b.group(outboundGroup != null ? outboundGroup : in.eventLoop())
             .channel(NioSocketChannel.class)
             .option(ChannelOption.AUTO_READ, false)
             .option(ChannelOption.TCP_NODELAY, true)
             .handler(new ChannelInitializer<Channel>() {
                 @Override protected void initChannel(Channel c) {
                     c.pipeline().addLast(READ_COUNTER).addLast(new ProxyBack(in));
                 }
             });
            ChannelFuture f = b.connect("127.0.0.1", backPort);
            out = f.channel();
            f.addListener(fu -> { if (fu.isSuccess()) { in.read(); } else { in.close(); } });
        }
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            Channel o = out;
            if (o != null && o.isActive()) {
                o.writeAndFlush(msg).addListener(fu -> {
                    if (fu.isSuccess()) { ctx.read(); } else { ctx.close(); }
                });
            } else {
                ReferenceCountUtil.release(msg);
            }
        }
        @Override public void channelInactive(ChannelHandlerContext ctx) { closeOnFlush(out); }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable t) { closeOnFlush(ctx.channel()); }
        static void closeOnFlush(Channel c) {
            if (c != null && c.isActive()) {
                c.writeAndFlush(Unpooled.EMPTY_BUFFER).addListener(ChannelFutureListener.CLOSE);
            }
        }
    }

    static final class ProxyBack extends ChannelInboundHandlerAdapter {
        private final Channel in;
        ProxyBack(Channel in) { this.in = in; }
        @Override public void channelActive(ChannelHandlerContext ctx) { ctx.read(); }
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            in.writeAndFlush(msg).addListener(fu -> {
                if (fu.isSuccess()) { ctx.read(); } else { ctx.close(); }
            });
        }
        @Override public void channelInactive(ChannelHandlerContext ctx) { ProxyFront.closeOnFlush(in); }
        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable t) { ProxyFront.closeOnFlush(ctx.channel()); }
    }
}
