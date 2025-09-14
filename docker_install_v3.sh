#!/bin/bash

# Docker自动安装脚本 v3.0
# 支持系统: CentOS 7/8, AnolisOS 23, openEuler 22.03/24.03+
# 特性: 清晰逻辑，简洁代码，完整功能，openEuler专用源支持

set -e  # 遇到错误立即退出

# =============================================================================
# 配置和常量
# =============================================================================

readonly SCRIPT_NAME="Docker 自动安装脚本 v3.0"
readonly BACKUP_DIR="/etc/yum.repos.d.backup"

# 系统配置映射 - 新增yum源配置支持
# 格式: "docker_os,版本,docker镜像源,工具包,安装参数,备用参数,yum源类型,yum源地址"
declare -A SYSTEM_CONFIG=(
    ["centos_7"]="centos,7,mirrors.aliyun.com,yum-utils,-y,-y,centos,mirrors.aliyun.com"
    ["centos_8"]="centos,8,mirrors.aliyun.com,yum-utils,-y --allowerasing,-y --nobest --allowerasing,centos,mirrors.aliyun.com"
    ["anolis"]="centos,8,mirrors.aliyun.com,yum-utils,-y --allowerasing,-y --nobest --allowerasing,centos,mirrors.aliyun.com"
    ["openeuler"]="centos,8,repo.huaweicloud.com,dnf-utils,-y --allowerasing,-y --nobest --allowerasing,openeuler,repo.huaweicloud.com"
)

# =============================================================================
# 工具函数
# =============================================================================

log_info() {
    echo -e "\033[32m✓\033[0m $1"
}

log_warn() {
    echo -e "\033[33m⚠\033[0m $1"
}

log_error() {
    echo -e "\033[31m✗\033[0m $1"
}

log_step() {
    echo ""
    echo "==============================================="
    echo "  $1"
    echo "==============================================="
}

confirm_action() {
    local prompt="$1"
    local response
    read -p "$prompt (y/n): " -n 1 -r response
    echo
    [[ $response =~ ^[Yy]$ ]]
}

# =============================================================================
# 系统检测和配置
# =============================================================================

detect_system() {
    log_step "系统检测"
    
    # 权限检查
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用root用户运行此脚本"
        echo "使用方法: sudo bash $(basename $0)"
        exit 1
    fi
    
    # yum兼容性检查
    if ! command -v yum &>/dev/null; then
        log_error "此脚本仅适用于基于yum的系统"
        exit 1
    fi
    
    # 读取系统信息
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
        echo "检测到操作系统: $PRETTY_NAME"
        echo "系统 ID: $OS_NAME, 版本: $OS_VERSION"
    else
        log_warn "无法检测操作系统版本，将按CentOS 8处理"
        OS_NAME="centos"
        OS_VERSION="8"
    fi
    
    # 确定系统配置键 - 先转换为小写便于匹配
    OS_NAME_LOWER=$(echo "$OS_NAME" | tr '[:upper:]' '[:lower:]')
    echo "原始ID: '$OS_NAME', 转换后ID: '$OS_NAME_LOWER'"
    
    case "$OS_NAME_LOWER" in
        "centos")
            [[ "$OS_VERSION" == "7" ]] && SYSTEM_KEY="centos_7" || SYSTEM_KEY="centos_8"
            echo "匹配到CentOS系统"
            ;;
        "anolis")
            SYSTEM_KEY="anolis"
            echo "匹配到AnolisOS系统"
            ;;
        "openeuler")
            SYSTEM_KEY="openeuler"
            echo "匹配到openEuler系统"
            ;;
        *)
            # 检查PRETTY_NAME中是否包含openEuler
            if [[ "$PRETTY_NAME" =~ [Oo]pen[Ee]uler ]]; then
                echo "通过PRETTY_NAME检测到openEuler系统: '$PRETTY_NAME'"
                SYSTEM_KEY="openeuler"
            else
                log_warn "未识别的系统 ($OS_NAME)，将使用CentOS 8兼容配置"
                SYSTEM_KEY="centos_8"
            fi
            ;;
    esac
    
    # 解析系统配置
    IFS=',' read -r DOCKER_REPO_OS DOCKER_REPO_VERSION DOCKER_MIRROR_HOST YUM_UTILS_PACKAGE YUM_INSTALL_PARAMS YUM_BACKUP_PARAMS YUM_SOURCE_TYPE YUM_SOURCE_HOST <<< "${SYSTEM_CONFIG[$SYSTEM_KEY]}"
    
    log_info "系统配置: $SYSTEM_KEY"
    log_info "Docker源: $DOCKER_MIRROR_HOST/$DOCKER_REPO_OS/$DOCKER_REPO_VERSION"
    log_info "YUM源类型: $YUM_SOURCE_TYPE"
    log_info "工具包: $YUM_UTILS_PACKAGE"
}

# =============================================================================
# yum源配置
# =============================================================================

configure_yum_repos() {
    log_step "步骤1: 配置yum源"
    
    if confirm_action "您是否已经配置了可用的yum源？"; then
        log_info "跳过yum源配置步骤"
        echo "正在测试yum源可用性..."
        if yum makecache --quiet &>/dev/null; then
            log_info "yum源测试通过"
        else
            log_warn "yum源测试失败，但将继续执行"
        fi
    else
        configure_new_yum_repos
    fi
}

configure_new_yum_repos() {
    echo "检测到需要配置新的yum源"
    echo "原有的源文件将会被备份到 $BACKUP_DIR 目录"
    
    if confirm_action "是否继续清理现有的yum源文件？"; then
        backup_and_clean_repos
        
        # 根据系统类型选择配置方法
        case "$YUM_SOURCE_TYPE" in
            "openeuler")
                configure_openeuler_repos
                ;;
            "centos")
                configure_centos_repos
                ;;
            *)
                log_error "不支持的yum源类型: $YUM_SOURCE_TYPE"
                exit 1
                ;;
        esac
    else
        log_warn "用户选择保留现有yum源，如遇问题请手动处理"
    fi
}

backup_and_clean_repos() {
    echo "正在清理原有的yum源文件..."
    if [[ -d "/etc/yum.repos.d" ]]; then
        mkdir -p "$BACKUP_DIR"
        mv /etc/yum.repos.d/*.repo "$BACKUP_DIR/" 2>/dev/null || true
        log_info "原有yum源文件已备份到 $BACKUP_DIR"
    fi
}

configure_openeuler_repos() {
    echo "正在配置openEuler专用软件源..."
    echo "使用经过验证的openEuler $OS_VERSION源配置"
    
    # 根据版本选择对应的源配置
    case "$OS_VERSION" in
        "22.03" | "22.03-LTS"*)
            echo "使用openEuler 22.03-LTS源配置"
            create_openeuler_2203_repos
            ;;
        "24.03" | "24.03-LTS"*)
            echo "使用openEuler 24.03源配置"
            create_openeuler_2403_repos
            ;;
        *)
            echo "未知版本 $OS_VERSION，尝试使用最新版本配置"
            create_openeuler_2403_repos
            ;;
    esac
    
    if [[ $? -eq 0 ]]; then
        log_info "openEuler源配置完成"
        test_yum_repos
    else
        log_error "openEuler源配置失败"
        exit 1
    fi
}

create_openeuler_2203_repos() {
    # openEuler 22.03-LTS经过验证的源配置
    cat > /etc/yum.repos.d/openEuler.repo << 'EOF'
[openEuler-everything]
name=openEuler-everything
baseurl=http://repo.huaweicloud.com/openeuler/openEuler-22.03-LTS/everything/x86_64/
enabled=1
gpgcheck=0
gpgkey=http://repo.huaweicloud.com/openeuler/openEuler-22.03-LTS/everything/x86_64/RPM-GPG-KEY-openEuler

[openEuler-EPOL]
name=openEuler-epol
baseurl=http://repo.huaweicloud.com/openeuler/openEuler-22.03-LTS/EPOL/main/x86_64/
enabled=1
gpgcheck=0

[openEuler-update]
name=openEuler-update
baseurl=http://repo.huaweicloud.com/openeuler/openEuler-22.03-LTS/update/x86_64/
enabled=1
gpgcheck=0
EOF
}

create_openeuler_2403_repos() {
    # openEuler 24.03经过验证的源配置
    cat > /etc/yum.repos.d/openEuler.repo << 'EOF'
[openEuler-everything]
name=openEuler-everything
baseurl=http://repo.huaweicloud.com/openeuler/openEuler-24.03-LTS/everything/x86_64/
enabled=1
gpgcheck=0
gpgkey=http://repo.huaweicloud.com/openeuler/openEuler-24.03-LTS/everything/x86_64/RPM-GPG-KEY-openEuler

[openEuler-EPOL]
name=openEuler-epol
baseurl=http://repo.huaweicloud.com/openeuler/openEuler-24.03-LTS/EPOL/main/x86_64/
enabled=1
gpgcheck=0

[openEuler-update]
name=openEuler-update
baseurl=http://repo.huaweicloud.com/openeuler/openEuler-24.03-LTS/update/x86_64/
enabled=1
gpgcheck=0
EOF
}

configure_centos_repos() {
    echo "正在下载CentOS源配置..."
    
    # 根据系统选择repo文件
    if [[ "$SYSTEM_KEY" == "centos_7" ]]; then
        REPO_URL="http://$YUM_SOURCE_HOST/repo/Centos-7.repo"
    else
        REPO_URL="http://$YUM_SOURCE_HOST/repo/Centos-8.repo"
    fi
    
    echo "下载源配置: $REPO_URL"
    if curl -o /etc/yum.repos.d/CentOS-Base.repo "$REPO_URL"; then
        log_info "CentOS源配置完成"
        test_yum_repos
    else
        log_error "CentOS源配置失败，但继续执行"
    fi
}

test_yum_repos() {
    echo "正在测试yum源可用性..."
    if yum clean all &>/dev/null && yum makecache &>/dev/null; then
        log_info "yum源测试通过"
    else
        log_warn "yum源测试失败，但将继续尝试安装"
    fi
}

# =============================================================================
# Docker源配置
# =============================================================================

configure_docker_repos() {
    log_step "步骤2: 配置Docker源"
    
    install_yum_utils
    create_docker_repo
    fix_openeuler_vars
    test_docker_repo
}

install_yum_utils() {
    echo "正在安装必要的系统工具..."
    echo "安装包: $YUM_UTILS_PACKAGE"
    
    if yum install -y "$YUM_UTILS_PACKAGE"; then
        log_info "$YUM_UTILS_PACKAGE 安装完成"
    else
        log_warn "$YUM_UTILS_PACKAGE 安装失败，尝试备用包名"
        install_alternative_utils
    fi
}

install_alternative_utils() {
    case "$YUM_UTILS_PACKAGE" in
        "dnf-utils")
            ALT_PACKAGE="yum-utils"
            ;;
        "yum-utils")
            ALT_PACKAGE="dnf-utils"
            ;;
        *)
            log_error "无法确定备用包名"
            exit 1
            ;;
    esac
    
    echo "尝试备用包名: $ALT_PACKAGE"
    if yum install -y "$ALT_PACKAGE"; then
        log_info "$ALT_PACKAGE 安装完成"
    else
        log_error "无法安装所需工具包"
        exit 1
    fi
}

create_docker_repo() {
    echo "正在创建Docker源配置..."
    echo "使用镜像源: $DOCKER_MIRROR_HOST"
    
    cat > /etc/yum.repos.d/docker-ce.repo << EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://$DOCKER_MIRROR_HOST/docker-ce/linux/$DOCKER_REPO_OS/$DOCKER_REPO_VERSION/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://$DOCKER_MIRROR_HOST/docker-ce/linux/$DOCKER_REPO_OS/gpg

[docker-ce-stable-debuginfo]
name=Docker CE Stable - Debuginfo \$basearch
baseurl=https://$DOCKER_MIRROR_HOST/docker-ce/linux/$DOCKER_REPO_OS/$DOCKER_REPO_VERSION/debug-\$basearch/stable
enabled=0
gpgcheck=1
gpgkey=https://$DOCKER_MIRROR_HOST/docker-ce/linux/$DOCKER_REPO_OS/gpg

[docker-ce-stable-source]
name=Docker CE Stable - Sources
baseurl=https://$DOCKER_MIRROR_HOST/docker-ce/linux/$DOCKER_REPO_OS/$DOCKER_REPO_VERSION/source/stable
enabled=0
gpgcheck=1
gpgkey=https://$DOCKER_MIRROR_HOST/docker-ce/linux/$DOCKER_REPO_OS/gpg
EOF
    
    if [[ $? -eq 0 ]]; then
        log_info "Docker源配置完成"
    else
        log_error "Docker源配置失败"
        exit 1
    fi
}

fix_openeuler_vars() {
    if [[ "$SYSTEM_KEY" == "openeuler" ]]; then
        echo "为openEuler系统修复\$releasever变量..."
        sed -i "s/\$releasever/$DOCKER_REPO_VERSION/g" /etc/yum.repos.d/docker-ce.repo
        log_info "\$releasever变量已修复为$DOCKER_REPO_VERSION"
    fi
}

test_docker_repo() {
    echo "正在测试Docker源可用性..."
    if yum makecache --disablerepo="*" --enablerepo="docker-ce-stable" &>/dev/null; then
        log_info "Docker源测试通过"
    else
        log_warn "Docker源测试失败，但将继续尝试安装"
    fi
}

# =============================================================================
# 冲突检测和解决
# =============================================================================

handle_conflicts() {
    log_step "步骤3: 检测并解决包冲突"
    
    # 检测冲突包
    local conflict_packages=""
    for pkg in podman buildah runc; do
        if rpm -q "$pkg" &>/dev/null; then
            conflict_packages="$conflict_packages $pkg"
        fi
    done
    
    if [[ -n "$conflict_packages" ]]; then
        handle_conflict_packages "$conflict_packages"
    else
        log_info "未检测到冲突包，可以直接安装Docker"
    fi
}

handle_conflict_packages() {
    local packages="$1"
    echo "检测到以下可能与Docker冲突的包:$packages"
    echo "这些包可能导致Docker安装失败，建议移除它们"
    echo "注意: 移除这些包可能会影响依赖它们的其他应用"
    
    if confirm_action "是否移除冲突的包？"; then
        echo "正在移除冲突的包:$packages"
        yum remove -y $packages
        log_info "冲突包已移除"
    else
        log_warn "用户选择保留冲突包，将尝试使用兼容参数安装Docker"
    fi
}

# =============================================================================
# Docker安装
# =============================================================================

install_docker() {
    log_step "步骤4: 安装Docker"
    
    install_core_components
    install_optional_components
}

install_core_components() {
    echo "正在安装Docker核心组件..."
    echo "组件: docker-ce docker-ce-cli containerd.io"
    echo "参数: $YUM_INSTALL_PARAMS"
    
    if yum install $YUM_INSTALL_PARAMS docker-ce docker-ce-cli containerd.io; then
        log_info "Docker核心组件安装完成"
    else
        try_fallback_installation
    fi
}

try_fallback_installation() {
    log_warn "Docker安装失败，尝试使用备用方法"
    
    if [[ "$SYSTEM_KEY" == "centos_7" ]]; then
        echo "正在尝试使用 --skip-broken 参数安装..."
        if yum install -y docker-ce docker-ce-cli containerd.io --skip-broken; then
            log_info "Docker安装完成 (使用备用方法)"
        else
            installation_failed
        fi
    else
        echo "正在尝试使用 --nobest 参数安装..."
        if yum install $YUM_BACKUP_PARAMS docker-ce docker-ce-cli containerd.io; then
            log_info "Docker安装完成 (使用备用方法)"
        else
            installation_failed
        fi
    fi
}

installation_failed() {
    log_error "Docker安装仍然失败"
    echo "建议手动执行: yum install -y docker-ce docker-ce-cli containerd.io --skip-broken"
    echo "或者尝试单独安装: yum install -y docker-ce"
    exit 1
}

install_optional_components() {
    echo ""
    echo "正在安装可选组件..."
    echo "- docker-buildx-plugin: Docker构建增强工具"
    echo "- docker-compose-plugin: Docker Compose v2插件"
    
    if yum install -y docker-buildx-plugin docker-compose-plugin 2>/dev/null; then
        log_info "可选组件安装完成"
    else
        log_warn "可选组件安装失败，但不影响Docker核心功能"
    fi
}

# =============================================================================
# 服务配置和验证
# =============================================================================

configure_service() {
    log_step "步骤5: 配置Docker服务"
    
    echo "正在启动Docker服务..."
    systemctl start docker
    
    echo "正在设置开机自启动..."
    systemctl enable docker
    
    log_info "Docker服务配置完成"
}

verify_installation() {
    log_step "步骤7: 验证安装"
    
    echo "正在验证Docker安装..."
    if docker --version &>/dev/null; then
        log_info "Docker安装验证成功"
        show_installation_info
    else
        log_error "Docker安装验证失败"
        exit 1
    fi
}

show_installation_info() {
    echo ""
    echo "==============================================="
    echo "    Docker安装完成!"
    echo "==============================================="
    echo "Docker版本信息:"
    docker --version
    echo ""
    if command -v docker-compose &>/dev/null || docker compose version &>/dev/null; then
        echo "Docker Compose版本信息:"
        docker compose version 2>/dev/null || docker-compose --version 2>/dev/null
        echo ""
    fi
    echo "使用提示:"
    echo "- Docker服务已启动并设置为开机自启"
    echo "- Docker镜像加速器已配置，提高镜像拉取速度"
    echo "- 您可以使用 'docker run hello-world' 测试Docker是否正常工作"
    echo "- 如需将普通用户加入docker组，请运行: usermod -aG docker <用户名>"
    echo ""
    echo "v3.0更新说明:"
    echo "- ✅ 新增对openEuler系统的专用yum源支持"
    echo "- ✅ 修复openEuler系统yum源配置问题"
    echo "- ✅ 保持对其他系统的完全兼容"
    echo "- ✅ 新增Docker镜像加速器自动配置"
    echo ""
}

# =============================================================================
# Docker镜像加速配置
# =============================================================================

configure_docker_mirrors() {
    log_step "步骤6: 配置Docker镜像加速"
    
    echo "正在配置Docker镜像加速器..."
    
    # 创建/etc/docker目录
    mkdir -p /etc/docker
    
    # 创建daemon.json文件
    cat > /etc/docker/daemon.json << 'EOF'
{
	"registry-mirrors": [
		"https://docker.m.daocloud.io",
		"https://dockerpull.com",
		"https://dockerhub.timeweb.cloud",
		"https://atomhub.openatom.cn",
		"https://docker.1panel.live",
		"https://dockerhub.jobcher.com",
		"https://hub.rat.dev",
		"https://docker.registry.cyou",
		"https://docker.awsl9527.cn",
		"https://do.nark.eu.org/",
		"https://docker.ckyl.me",
		"https://hub.uuuadc.top",
		"https://docker.chenby.cn",
		"https://docker.ckyl.me",
		"https://mirror.ccs.tencentyun.com",
		"https://docker.mirrors.ustc.edu.cn",
		"http://hub-mirror.c.163.com",
		"https://docker.nju.edu.cn"
	]
}
EOF
    
    if [[ $? -eq 0 ]]; then
        log_info "Docker镜像加速配置文件创建完成"
    else
        log_error "Docker镜像加速配置失败"
        exit 1
    fi
    
    # 重启 Docker 服务
    echo "正在重启Docker服务以应用配置..."
    systemctl restart docker
    
    if [[ $? -eq 0 ]]; then
        log_info "Docker服务重启成功"
    else
        log_error "Docker服务重启失败"
        exit 1
    fi
    
    # 测试镜像加速器
    test_docker_mirrors
}

test_docker_mirrors() {
    echo "正在测试Docker镜像加速器..."
    echo "使用 'docker pull busybox' 测试镜像拉取速度"
    
    # 记录开始时间
    start_time=$(date +%s)
    
    if docker pull busybox >/dev/null 2>&1; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        log_info "Docker镜像拉取测试成功（耗时: ${duration}秒）"
        echo "镜像加速器配置成功！"
    else
        log_warn "Docker镜像拉取测试失败，但不影响正常使用"
        echo "可能是网络问题，请稍后手动测试: docker pull busybox"
    fi
}

# =============================================================================
# 主流程
# =============================================================================

main() {
    echo "==============================================="
    echo "    $SCRIPT_NAME"
    echo "==============================================="
    echo ""
    echo "v3.0更新特性:"
    echo "- 专门优化openEuler系统支持"
    echo "- 修复openEuler yum源配置问题"
    echo "- 使用华为云openEuler官方镜像源"
    echo "- 保持其他系统完全兼容"
    echo ""
    
    detect_system
    configure_yum_repos
    configure_docker_repos
    handle_conflicts
    install_docker
    configure_service
    configure_docker_mirrors
    verify_installation
    
    log_info "安装流程全部完成!"
}

# 运行主函数
main "$@"