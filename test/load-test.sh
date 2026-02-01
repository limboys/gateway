#!/bin/bash
# load-test.sh - 压测快速启动脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查 STRESS_TEST_MODE
check_stress_mode() {
    echo -e "${YELLOW}🔍 Checking STRESS_TEST_MODE...${NC}"
    
    # 确定项目根目录
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/.." && pwd)"
    local env_file="$project_root/.env"
    
    if [ -f "$env_file" ] && grep -q "STRESS_TEST_MODE=true" "$env_file" 2>/dev/null; then
        echo -e "${GREEN}✅ STRESS_TEST_MODE=true (found in $env_file)${NC}"
    else
        echo -e "${RED}❌ STRESS_TEST_MODE not enabled!${NC}"
        echo -e "${YELLOW}Fix: Add 'STRESS_TEST_MODE=true' to $env_file${NC}"
        echo -e "${YELLOW}Or run: echo 'STRESS_TEST_MODE=true' >> $env_file${NC}"
        exit 1
    fi
    
    # 检查容器环境变量
    cd "$project_root"
    if docker-compose exec -T api-proxy env 2>/dev/null | grep -q "STRESS_TEST_MODE=true"; then
        echo -e "${GREEN}✅ STRESS_TEST_MODE active in container${NC}"
    else
        echo -e "${YELLOW}⚠️  STRESS_TEST_MODE not active in container${NC}"
        echo -e "${YELLOW}⚠️  Need to restart: docker-compose restart api-proxy${NC}"
        read -p "$(echo -e ${YELLOW}Restart now? [y/N]:${NC} )" -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}🔄 Restarting api-proxy...${NC}"
            docker-compose restart api-proxy
            sleep 5
            echo -e "${GREEN}✅ Service restarted${NC}"
        else
            echo -e "${RED}❌ Please restart manually: docker-compose restart api-proxy${NC}"
            exit 1
        fi
    fi
    cd - > /dev/null
}

# 清空 Redis
clear_redis() {
    echo -e "${YELLOW}🗑️  Clearing Redis...${NC}"
    
    # 确定项目根目录
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/.." && pwd)"
    
    cd "$project_root"
    
    # 从 .env 读取 Redis 密码
    local redis_password=$(grep "REDIS_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2)
    if [ -z "$redis_password" ]; then
        redis_password="change-me"
    fi
    
    if docker exec api-proxy-redis redis-cli -a "$redis_password" FLUSHDB > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Redis cleared${NC}"
    else
        echo -e "${YELLOW}⚠️  Failed to clear Redis (may not be running)${NC}"
    fi
    
    cd - > /dev/null
}

# 运行压测
run_load_test() {
    local concurrency=${1:-100}
    local duration=${2:-60}
    local report=${3:-""}
    
    echo -e "${YELLOW}🚀 Starting load test...${NC}"
    echo -e "   Concurrency: ${concurrency}"
    echo -e "   Duration: ${duration}s"
    
    # 确定项目根目录
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/.." && pwd)"
    
    cd "$project_root"
    
    local cmd="python3 test/enhanced_auto_test.py \
        --base-url http://localhost:8080 \
        --load-only \
        --load-concurrency ${concurrency} \
        --load-duration ${duration}"
    
    if [ -n "$report" ]; then
        mkdir -p results
        cmd="$cmd --report results/${report}"
        echo -e "   Report: results/${report}"
    fi
    
    eval $cmd
    
    cd - > /dev/null
}

# 显示帮助
show_help() {
    cat << EOF
${GREEN}压测脚本使用说明${NC}

用法: $0 [SCENARIO] [OPTIONS]

${YELLOW}场景选择:${NC}
  light      轻量压测 (50并发, 30秒)
  medium     中等压测 (200并发, 60秒)
  heavy      极限压测 (500并发, 120秒)
  custom     自定义 (需要 -c 和 -d 参数)

${YELLOW}选项:${NC}
  -c NUM     并发数 (默认: 100)
  -d NUM     持续时间/秒 (默认: 60)
  -r FILE    保存报告到 results/FILE
  --no-clear 不清空 Redis
  --no-check 不检查配置
  -h, --help 显示帮助

${YELLOW}示例:${NC}
  # 轻量压测
  $0 light

  # 中等压测并保存报告
  $0 medium -r medium-test-20260201.json

  # 自定义压测
  $0 custom -c 300 -d 90

  # 极限压测
  $0 heavy

${YELLOW}压测前检查:${NC}
  1. 确保 .env 中 STRESS_TEST_MODE=true
  2. 重启服务: docker-compose restart api-proxy
  3. 验证环境: docker-compose exec api-proxy env | grep STRESS

EOF
}

# 主函数
main() {
    local scenario=""
    local concurrency=100
    local duration=60
    local report=""
    local do_clear=true
    local do_check=true
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            light)
                scenario="light"
                concurrency=50
                duration=30
                shift
                ;;
            medium)
                scenario="medium"
                concurrency=200
                duration=60
                shift
                ;;
            heavy)
                scenario="heavy"
                concurrency=500
                duration=120
                shift
                ;;
            custom)
                scenario="custom"
                shift
                ;;
            -c)
                concurrency=$2
                shift 2
                ;;
            -d)
                duration=$2
                shift 2
                ;;
            -r)
                report=$2
                shift 2
                ;;
            --no-clear)
                do_clear=false
                shift
                ;;
            --no-check)
                do_check=false
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 如果没有指定场景，显示帮助
    if [ -z "$scenario" ]; then
        show_help
        exit 1
    fi
    
    # 检查配置
    if [ "$do_check" = true ]; then
        check_stress_mode
    fi
    
    # 清空 Redis
    if [ "$do_clear" = true ]; then
        clear_redis
    fi
    
    # 运行压测
    run_load_test "$concurrency" "$duration" "$report"
    
    echo -e "${GREEN}✅ Load test completed!${NC}"
}

# 执行主函数
main "$@"
