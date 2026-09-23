// Minimal Qt Widgets demo for the "linuxfb" QPA platform: a fullscreen
// digital clock. No window manager, no X11/Wayland -- Qt draws straight
// into the mmap'd /dev/fb0.
#include <QApplication>
#include <QLCDNumber>
#include <QPalette>
#include <QTime>
#include <QTimer>

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    QLCDNumber clock;
    clock.setDigitCount(8);
    clock.setSegmentStyle(QLCDNumber::Filled);
    clock.setWindowTitle(QStringLiteral("centos-bootc-cfs Qt demo"));

    QPalette palette = clock.palette();
    palette.setColor(QPalette::Window, Qt::black);
    palette.setColor(QPalette::WindowText, Qt::green);
    palette.setColor(QPalette::Light, Qt::green);
    palette.setColor(QPalette::Dark, Qt::darkGreen);
    clock.setPalette(palette);
    clock.setAutoFillBackground(true);

    auto updateClock = [&clock]() {
        clock.display(QTime::currentTime().toString(QStringLiteral("hh:mm:ss")));
    };
    updateClock();

    QTimer timer;
    QObject::connect(&timer, &QTimer::timeout, &clock, updateClock);
    timer.start(1000);

    clock.showFullScreen();
    return app.exec();
}
