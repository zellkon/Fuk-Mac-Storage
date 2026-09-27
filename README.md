# Fuk Mac Storage

App macOS native bằng SwiftUI, chạy hoàn toàn local, không backend, không analytics và không thư viện bên thứ ba. Giao diện tiếng Anh mặc định, có thể đổi sang tiếng Việt trong Settings. Yêu cầu macOS 13 trở lên; bản build Universal hỗ trợ Apple Silicon và Intel.

Docker chỉ xuất hiện trong sidebar sau khi Scan xác nhận Docker CLI và local daemon hoạt động. Ứng dụng không hiển thị cấu trúc `Library` trong giao diện; thay vào đó nhóm dữ liệu thành App caches, Build caches, Log files, Apps & data và các công cụ developer. Các mục app/developer và thư mục cá nhân lớn có thể dọn từng mục, nhưng yêu cầu gõ `MOVE TO TRASH`; cache/log chỉ cần xác nhận thông thường. Mục symbolic link hoặc quét chưa đầy đủ vẫn bị chặn.

## Mở app

Giải nén `Fuk-Mac-Storage-macOS.zip`, mở `Fuk Mac Storage.app` hoặc kéo vào Applications. Đây là bản build local ký ad-hoc, chưa có Developer ID/notarization. Nếu macOS chặn bản tải xuống, kiểm tra nguồn rồi dùng System Settings → Privacy & Security → Open Anyway; hoặc tự build bằng Xcode. Không cần tắt Gatekeeper.

## Mở project bằng Xcode

1. Mở `SafeSpace.xcodeproj`.
2. Chọn scheme **SafeSpace**, destination **My Mac**.
3. Run (⌘R). Không cần backend hay package ngoài.

Project mặc định ký “Sign to Run Locally”. Nếu muốn phân phối, chọn Team/Developer ID của bạn và thực hiện notarization. App không bật App Sandbox để có thể quét các nhóm thư mục được yêu cầu; vẫn chịu các quyền truy cập macOS/TCC thông thường. Không dùng quyền root, helper đặc quyền hay `sudo`.

Build Universal và zip lại bằng `./build.sh`. Kết quả trong `dist/`.

Chạy test core qua Swift Package: `swift test`. Xcode project dành cho app; mở `Package.swift` để chạy package tests từ Xcode. Xcode 15+ có thể dùng source này; bản bàn giao được kiểm tra bằng Xcode 26.1.1.

## Cách dùng

- **Scan**: quét các nhóm và đọc Docker. Không tự chạy khi mở app.
- **Refresh**: quét lại; ở trang Docker chỉ cập nhật Docker.
- **Dừng quét**: giữ kết quả một phần và ghi rõ trạng thái đó.
- **Open in Finder**: mở nhóm; biểu tượng thư mục trên từng dòng giúp tìm mục cụ thể.
- Tick từng mục trong User Caches, Gradle Caches hoặc Logs. Không có mục nào được chọn sẵn.
- **Clean Selected** mở danh sách đường dẫn và dung lượng ước tính của toàn bộ lựa chọn, kể cả lựa chọn ở nhóm khác.
- Đóng các ứng dụng liên quan, dừng build/Gradle, xác nhận rồi chuyển vào Thùng rác. Có thể khôi phục bằng Finder → Trash → Put Back khi Finder hỗ trợ. SafeSpace không tự làm trống Thùng rác.
- Dung lượng chỉ thực sự được giải phóng khi bạn tự làm trống Thùng rác và filesystem không còn giữ dữ liệu trong snapshots/clones. Số “Đã chọn” không phải dung lượng đã giải phóng.

## Nhóm dữ liệu và rào chắn

| Nhóm | Quyền trong app |
|---|---|
| `~/Library/Caches` | Chọn từng mục con trực tiếp và chuyển vào Thùng rác |
| `~/.gradle/caches` | Tương tự; lần build tiếp theo có thể cần mạng để tải dependencies |
| `~/Library/Logs` | Tương tự; cân nhắc giữ log phục vụ chẩn đoán |
| `~/Library/Developer` | Chỉ xem |
| `~/Library/Android` | Chỉ xem |
| `~/Library/Arduino15` | Chỉ xem |
| `~/Library/Application Support` | Chỉ xem |
| Home, gồm thư mục ẩn | Chỉ xem; sắp theo dung lượng giảm dần |
| Docker | Chỉ dọn qua Docker CLI, từng mức xác nhận riêng |

Scanner chỉ đọc metadata (`lstat`, disk blocks), không đọc nội dung file, không theo symbolic link và không đi qua filesystem khác. Mục quét thiếu do lỗi/quyền truy cập bị khoá dọn. Kích thước là disk allocation ước tính; không phải logical file size. Dedupe hard link trong từng mục, nhưng clones/hard links giữa các mục vẫn có thể tính trùng. Nhóm Home bao gồm Library/.gradle nên không cộng các nhóm thành tổng.

Trước mỗi lần chuyển vào Thùng rác, policy kiểm tra lại allowlist, đường dẫn canonical, symlink, device và inode đã ghi khi scan. Không cho chọn cả root cache/log, đường dẫn con tuỳ ý hoặc thư mục ngoài allowlist. Thư mục được chọn được chuyển toàn bộ: nội dung có thể thay đổi giữa lúc quét và dọn. Hãy đóng app/build liên quan để giảm tranh chấp; đây không phải một filesystem snapshot hay công cụ chống tiến trình độc hại thay đường dẫn đồng thời.

Nếu thiếu quyền: app hiển thị lỗi, không coi phần chưa đọc là đã quét đủ. Khi thực sự cần, cấp Full Disk Access cho bản SafeSpace đang dùng trong System Settings → Privacy & Security, khởi động lại app và Refresh. Không có logic tự nâng quyền.

## Docker

Cần Docker CLI và daemon đang hoạt động. App tìm CLI ở vị trí Docker Desktop/Homebrew thông dụng. Không tự khởi động Docker Desktop.

Đọc context hiện tại, chỉ chấp nhận endpoint `unix:///…`, rồi ghim endpoint đó bằng `--host` cho `docker system df` và prune. Không kế thừa `DOCKER_HOST`, `DOCKER_CONTEXT` hoặc `DOCKER_API_VERSION` từ môi trường app. Context dùng TCP/SSH bị chặn, kể cả TCP localhost. Unix socket thông thường trỏ vào daemon local; app không xác thực daemon phía sau một socket/proxy do người dùng tự dựng.

| Mức | Lệnh sau xác nhận |
|---|---|
| Build cache không dùng | `docker builder prune --all --force` |
| Dangling images | `docker image prune --force` |
| Containers đã dừng | `docker container prune --force` |
| System cơ bản | `docker system prune --force` |
| System + mọi image không dùng | `docker system prune --all --force` |
| Volumes riêng | `docker volume prune --force` |

Mỗi lần dọn có cảnh báo và xác nhận riêng. Volumes yêu cầu thêm chuỗi `DELETE VOLUMES`. Các mức system không gắn `--volumes`; để tách rõ rủi ro, app dành hành động riêng cho volumes. Không cung cấp `volume prune --all` cho named volumes. Theo Docker hiện hành, volume prune mặc định chọn anonymous volumes không còn được container tham chiếu; daemon cũ có thể khác. “Không dùng” không có nghĩa là dữ liệu không còn quan trọng. Container đã dừng cũng có thể chứa dữ liệu duy nhất trong writable layer.

[Docker system prune](https://docs.docker.com/reference/cli/docker/system/prune/), [builder prune](https://docs.docker.com/reference/cli/docker/builder/prune/), [volume prune](https://docs.docker.com/reference/cli/docker/volume/prune/).

Bảng Reclaimable lấy từ `docker system df --format '{{json .}}'`. Đây là ước lượng theo nhóm, không phải dry-run từng hành động; không cộng số đó vào ước lượng cache/log. Báo cáo quá 5 phút bị từ chối khi prune. Kết quả prune thật hiện trong Nhật ký; báo cáo được Refresh sau đó. Docker Desktop có thể chưa trả dung lượng của disk image về macOS ngay.

Read commands timeout sau 60 giây, prune sau 10 phút. Nếu CLI timeout/đóng app giữa prune, daemon có thể vẫn tiếp tục xử lý: Refresh trước khi chạy lại. App không dùng shell để thực thi lệnh, không xoá trực tiếp `Docker.raw` hoặc thư mục Docker. Nhật ký chỉ giữ trong bộ nhớ phiên app.

## Kiểm chứng

15 tests trên thư mục fixture tạm: allowlist, thư mục được bảo vệ, symlink ở mục/root/ancestor, đường dẫn root/nested bị chặn, inode thay đổi sau scan, missing folder, hard link, nested symlink, cancellation, Docker endpoint và phân tách volumes, output/timeout của tiến trình. Tests không prune Docker thật và không chuyển dữ liệu người dùng vào Thùng rác.

Source: `Sources/SafeSpace` chứa SwiftUI và state; `Sources/SafeSpaceCore` chứa scanner, cleanup policy và Docker service. `Tests/SafeSpaceCoreTests` chứa tests.
