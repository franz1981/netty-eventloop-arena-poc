import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.ByteBufAllocator;
import io.netty.channel.*;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * E2E launcher: same example pipelines as netty's HttpSnoopServer (h1) / Http2Server (h2), allocator
 * chosen by arg, transport chosen by {@code -Dtransport=nio|epoll|io_uring} (see {@link Transports}).
 *
 * usage: E2EServer &lt;allocator&gt; &lt;h1|h2&gt; &lt;port&gt; &lt;loops&gt;
 */
public class E2EServer {
    public static void main(String[] args) throws Exception {
        String alloc = args[0], proto = args[1]; int port = Integer.parseInt(args[2]); int loops = Integer.parseInt(args[3]);
        ByteBufAllocator allocator;
        switch (alloc) {
            case "adaptive": allocator = new io.netty.buffer.AdaptiveByteBufAllocator(); break;
            case "arena": allocator = new io.netty.buffer.CycleArenaAllocator(); break;
            case "mimalloc": allocator = new io.github.neoionet.netty.mimalloc.MiByteBufAllocator(); break;
            default: throw new IllegalArgumentException(alloc);
        }
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println(Transports.ringCounters());
            if ("arena".equals(alloc)) {
                System.out.println(io.netty.buffer.CycleArenaAllocator.counters());
            }
            System.out.flush();
        }));
        EventLoopGroup boss = new MultiThreadIoEventLoopGroup(1, Transports.bossFactory());
        EventLoopGroup workers = new MultiThreadIoEventLoopGroup(loops, Transports.workerFactory(allocator));
        // after the groups: the buffer-ring description is only known once workerFactory() ran.
        System.out.println("TRANSPORT " + Transports.describe());
        final ChannelHandler init = "h2".equals(proto)
                ? new io.netty.example.http2.helloworld.server.Http2ServerInitializer(null)
                : new io.netty.example.http.snoop.HttpSnoopServerInitializer(null);
        final AtomicBoolean optionsLogged = new AtomicBoolean();
        ChannelHandler child = new ChannelInitializer<Channel>() {
            @Override protected void initChannel(Channel ch) {
                if (optionsLogged.compareAndSet(false, true)) {
                    // Read the transport options back off the first accepted channel: this says the
                    // channel config accepted and stored them, not that the kernel used them.
                    System.out.println("CHILDOPTS " + Transports.childOptionsReadBack(ch));
                    System.out.flush();
                }
                ch.pipeline().addLast(init);
                // v3: the arena closes its iteration from the event loop's own tail-task hook; the earlier
                // per-channel channelReadComplete handler was dropped (netty commit 58a79ebd42).
            }
        };
        ServerBootstrap b = new ServerBootstrap();
        b.group(boss, workers).channel(Transports.serverChannel())
         .option(ChannelOption.ALLOCATOR, allocator).childOption(ChannelOption.ALLOCATOR, allocator)
         .childHandler(child);
        Transports.childOptions(b);
        Channel ch = b.bind(port).sync().channel();
        System.out.println("READY " + alloc + " " + proto + " " + port + " loops=" + loops
                + " transport=" + Transports.NAME);
        ch.closeFuture().sync();
    }
}
