
#include <QApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QTimer>
#include <QWindow>
#include <QContextMenuEvent>
#include <QDrag>
#include <QDropEvent>
#include <QLineEdit>
#include <QMenu>
#include <QLabel>
#include <QMimeData>
#include <QMouseEvent>
#include <QWidget>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static void write_text(const char *path, const QString &text) {
    if (!path) return;
    FILE *file = fopen(path, "w");
    if (!file) return;
    fputs(text.toUtf8().constData(), file);
    fclose(file);
}

class Menu : public QMenu {
public:
    Menu(const QString &name, QWidget *parent) : QMenu(name, parent), name_(name) {
        setMouseTracking(true);
        connect(this, &QMenu::hovered, this, [this](QAction *a) { report("hovered", a); });
        connect(this, &QMenu::aboutToShow, this, [this]() { report("aboutToShow"); });
        connect(this, &QMenu::aboutToHide, this, [this]() { report("aboutToHide"); });
        setStyleSheet(QString("QMenu { background: %1; color: black; border: 2px solid black; }")
                      .arg(name == "root" ? "#e04040" : name == "child" ? "#40e040" : "#4040e0"));
    }
    void report(const char *event, QAction *action = nullptr) {
        QJsonArray items;
        for (auto *a : actions()) {
            QRect r = actionGeometry(a);
            QPoint p = mapToGlobal(r.center());
            items.append(QJsonObject{{"text", a->text()}, {"x", p.x()}, {"y", p.y()}});
        }
        auto *w = windowHandle();
        QJsonObject obj{{"menu", name_}, {"event", event}, {"visible", isVisible()},
                        {"surface", w && w->isVisible()},
                        {"x", x()}, {"y", y()}, {"w", width()}, {"h", height()},
                        {"items", items}, {"action", action ? action->text() : ""}};
        if (event == QString("motion")) {
            QPoint p = mapFromGlobal(QCursor::pos());
            obj.insert("local_x", p.x()); obj.insert("local_y", p.y());
        }
        auto line = QJsonDocument(obj).toJson(QJsonDocument::Compact);
        fprintf(stderr, "MENU %s\n", line.constData()); fflush(stderr);
    }
protected:
    bool event(QEvent *event) override {
        bool result = QMenu::event(event);
        if (event->type() == QEvent::Paint) report("paint");
        if (event->type() == QEvent::MouseMove) report("motion");
        return result;
    }
private:
    QString name_;
};

class Probe : public QWidget {
public:
    explicit Probe(bool source) : source_(source), pressed_(false) {
        setWindowTitle("RayWM Qt DnD probe");
        setWindowFlags(Qt::FramelessWindowHint);
        resize(320, 200);
        setAcceptDrops(!source_);
        label_ = new QLabel(source_ ? "DRAG-QT" : "DROP-QT", this);
        label_->setGeometry(0, 0, 200, 40);
        if (!source_) {
            edit_ = new QLineEdit(this);
            edit_->setGeometry(0, 40, 300, 30);
            edit_->setText("primary-qt");
        }
        label_->setAlignment(Qt::AlignLeft | Qt::AlignTop);
        QPalette palette = this->palette();
        palette.setColor(QPalette::Window, source_ ? QColor(255, 255, 0) : QColor(0, 255, 255));
        setPalette(palette);
        setAutoFillBackground(true);
    }
protected:
    void mousePressEvent(QMouseEvent *event) override {
        fprintf(stderr, "qt press button=%d source=%d\n", (int) event->button(), source_ ? 1 : 0);
        fflush(stderr);
        if (source_ && event->button() == Qt::LeftButton) {
            pressed_ = true;
            start_ = event->pos();
        }
    }
    void mouseMoveEvent(QMouseEvent *event) override {
        if (!source_ || !pressed_ || !(event->buttons() & Qt::LeftButton)) return;
        if ((event->pos() - start_).manhattanLength() < QApplication::startDragDistance()) return;
        pressed_ = false;
        auto *drag = new QDrag(this);
        auto *mime = new QMimeData;
        mime->setText("qt-to-gtk");
        drag->setMimeData(mime);
        drag->exec(Qt::CopyAction);
    }
    void mouseReleaseEvent(QMouseEvent *) override { pressed_ = false; }
    void dragEnterEvent(QDragEnterEvent *event) override {
        fprintf(stderr, "qt dragEnter text=%d formats=%s\n", event->mimeData()->hasText() ? 1 : 0,
                event->mimeData()->formats().join(",").toUtf8().constData());
        fflush(stderr);
        if (event->mimeData()->hasText()) event->acceptProposedAction();
    }
    void dropEvent(QDropEvent *event) override {
        fprintf(stderr, "qt drop text=%d\n", event->mimeData()->hasText() ? 1 : 0);
        fflush(stderr);
        if (event->mimeData()->hasText()) {
            write_text(getenv("DROP_FILE"), event->mimeData()->text());
            event->acceptProposedAction();
        }
    }
    void contextMenuEvent(QContextMenuEvent *event) override {
        fprintf(stderr, "qt context menu\n"); fflush(stderr);
        Menu menu("root", this);
        menu.addAction("CTX-QT");
        Menu child("child", &menu);
        child.setTitle("MORE-QT");
        menu.addMenu(&child);
        child.addAction("NESTED-QT");
        Menu grand("grand", &child);
        grand.setTitle("DEEPER-QT");
        child.addMenu(&grand);
        grand.addAction("LEAF-QT");
        menu.exec(event->globalPos());
    }
private:
    bool source_;
    bool pressed_;
    QPoint start_;
    QLabel *label_;
    QLineEdit *edit_ = nullptr;
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    const char *role = getenv("PROBE_ROLE");
    bool source = role && strcmp(role, "source") == 0;
    Probe probe(source);
    probe.show();
    return app.exec();
}
