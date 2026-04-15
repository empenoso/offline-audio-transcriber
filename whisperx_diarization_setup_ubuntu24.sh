#!/usr/bin/env bash

# 🛠️ Скрипт установки WhisperX с диаризацией (Docker + NVIDIA) 🛠️
#
# Этот Shell-скрипт полностью автоматизирует подготовку системы Ubuntu
# (20.04/22.04/24.04) для работы с WhisperX через Docker с ускорением на GPU
# от NVIDIA. Он устанавливает все компоненты, настраивает их и создает
# готовое к работе окружение.
#
# Напоминание: скрипт следует официальным инструкциям NVIDIA и Docker
# для обеспечения максимальной надежности и совместимости.
#
# Основные задачи:
# - Проверка системы: Определяет дистрибутив и наличие драйверов NVIDIA.
# - Установка Docker: Устанавливает Docker Engine и добавляет пользователя
#   в нужную группу для работы без `sudo`.
# - Установка NVIDIA Container Toolkit: Позволяет Docker-контейнерам
#   напрямую использовать ресурсы GPU.
# - Тестирование GPU в Docker: Запускает тестовый контейнер для проверки
#   корректности настройки.
# - Загрузка образа WhisperX: Скачивает готовый Docker-образ со всеми
#   зависимостями.
# - Создание рабочего пространства:
#   - Локальные папки `audio/` и `results/`.
#   - Глобальный кеш для моделей в `~/whisperx/` для экономии места.
#   - Файл конфигурации `config.env` с настройками по умолчанию.
# - Управление правами: Назначает корректные права на папки, чтобы избежать
#   конфликтов доступа у Docker-контейнера.
#
# Порядок использования:
# 1. Сделайте скрипт исполняемым: chmod +x whisperx_diarization_setup_ubuntu24.sh
# 2. Запустите его: ./whisperx_diarization_setup_ubuntu24.sh
# 3. После завершения может потребоваться перезагрузка системы.

#  Следить за состоянием GPU: $ watch -n 5 nvidia-smi
#
# Автор: Михаил Шардин https://shardin.name/ 
# Дата создания: 14.09.2025
# Версия: 2.2
#
# Актуальная версия скрипта всегда здесь: https://github.com/empenoso/offline-audio-transcriber
#
# ===================================================================

## Строгий режим для bash. Прерывает выполнение при любой ошибке.
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции логирования (используем printf для большей надежности)
log()     { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
warning() { printf "${YELLOW}[WARNING]${NC} %s\n" "$1"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; } # Ошибки выводим в stderr

# --- Функции проверки системы ---

check_distro() {
    if ! [ -f /etc/os-release ]; then
        error "Не удалось определить операционную систему."
        exit 1
    fi
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        error "Этот скрипт предназначен для Ubuntu/Debian. Обнаружено: $PRETTY_NAME"
        exit 1
    fi
    success "Обнаружена совместимая система: $PRETTY_NAME"
}

check_gpu() {
    log "Проверка наличия NVIDIA GPU и драйверов..."
    if ! command -v nvidia-smi &> /dev/null; then
        error "Команда 'nvidia-smi' не найдена. Установите драйверы NVIDIA."
        printf "Рекомендуемые команды:\n"
        printf "  sudo ubuntu-drivers autoinstall\n"
        printf "  sudo reboot\n"
        exit 1
    fi
    if ! nvidia-smi &> /dev/null; then
        error "'nvidia-smi' не отвечает. Возможно, требуется перезагрузка после установки драйверов."
        exit 1
    fi
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits)
    DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits)
    success "Найден GPU: $GPU_INFO"
    log "Версия драйвера: $DRIVER_VERSION"
}

# --- Функции установки компонентов ---

install_docker() {
    if command -v docker &> /dev/null && docker --version &> /dev/null; then
        success "Docker уже установлен: $(docker --version)"
    else
        log "Установка Docker Engine..."
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        success "Docker успешно установлен."
    fi

    # Добавление пользователя в группу docker, если еще не там
    if ! groups "$USER" | grep -q '\bdocker\b'; then
        log "Добавление пользователя $USER в группу docker..."
        sudo usmod -aG docker "$USER"
        warning "Для применения изменений группы docker требуется перезагрузка или перелогин."
        log "Вы можете выполнить 'sudo reboot' после завершения установки."
    fi
}

install_nvidia_toolkit() {
    log "Установка NVIDIA Container Toolkit..."
    
    if command -v nvidia-ctk &> /dev/null; then
        success "NVIDIA Container Toolkit уже установлен."
    else
        log "Настройка репозитория NVIDIA..."
        # Этот метод автоматически определяет версию дистрибутива (ubuntu22.04, ubuntu24.04 и т.д.)
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
          && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
        
        log "Обновление списка пакетов и установка..."
        sudo apt-get update
        sudo apt-get install -y nvidia-container-toolkit
        success "NVIDIA Container Toolkit успешно установлен."
    fi

    log "Конфигурирование Docker для работы с NVIDIA GPU..."
    sudo nvidia-ctk runtime configure --runtime=docker
    
    log "Перезапуск Docker daemon для применения конфигурации..."
    sudo systemctl restart docker
    sleep 3 # Даем демону время на перезапуск
    success "Docker настроен для работы с NVIDIA GPU."
}

test_docker_gpu() {
    log "Тестирование Docker с поддержкой GPU..."
    if ! sudo docker run --rm hello-world > /dev/null 2>&1; then
        error "Базовый Docker не работает. Проверьте 'systemctl status docker'"
        exit 1
    fi
    success "Базовый тест Docker пройден."

    log "Проверка доступа к GPU из контейнера..."
    local cuda_image="nvidia/cuda:12.4.1-base-ubuntu22.04" # Используем актуальный образ
    log "Используем тестовый образ: $cuda_image"

    if ! sudo docker pull "$cuda_image" > /dev/null; then
        warning "Не удалось загрузить тестовый образ $cuda_image. Пропускаем тест GPU."
        return 1
    fi

    # Пытаемся выполнить nvidia-smi внутри контейнера
    local gpu_name_in_container
    gpu_name_in_container=$(sudo docker run --rm --gpus all "$cuda_image" nvidia-smi --query-gpu=name --format=csv,noheader)

    if [[ -n "$gpu_name_in_container" ]]; then
        success "🎉 GPU успешно обнаружен в Docker контейнере: $gpu_name_in_container"
        return 0 # Успех
    else
        error "Не удалось получить доступ к GPU из Docker контейнера."
        warning "WhisperX будет работать на CPU (значительно медленнее)."
        log "Возможные причины:"
        log " - Конфликт версий драйвера, toolkit или docker."
        log " - Необходимо перезагрузить систему: 'sudo reboot'"
        return 1 # Неудача
    fi
}

pull_whisperx_image() {
    log "Загрузка Docker образа WhisperX..."
    local whisperx_image="ghcr.io/jim60105/whisperx:latest" 
    
    if sudo docker pull "$whisperx_image"; then
        success "Образ $whisperx_image загружен успешно."
        local image_size_bytes
        image_size_bytes=$(sudo docker image inspect "$whisperx_image" --format='{{.Size}}')
        local image_size_gb
        image_size_gb=$(awk "BEGIN {printf \"%.2f\", $image_size_bytes/1024/1024/1024}")
        log "Размер образа: ~${image_size_gb} GB"
    else
        error "Не удалось загрузить образ WhisperX: $whisperx_image"
        exit 1
    fi
}

setup_workspace() {
    log "Создание рабочих директорий и конфигурации..."
    local base_dir="."
    local cache_dir="$HOME/whisperx"
    
    mkdir -p "$base_dir"/{audio,results}
    mkdir -p "$cache_dir"
    
    log "Установка прав 777 на папки..."
    chmod -R 777 "$base_dir"/audio "$base_dir"/results "$cache_dir"
    
    success "Созданы директории:"
    printf "  📂 %s/audio   - для входных аудиофайлов\n" "$(pwd)"
    printf "  📂 %s/results - для результатов\n" "$(pwd)"
    printf "  🧠 %s    - для кеширования моделей\n" "$cache_dir"

    local config_file="$base_dir/config.env"
    if [ -f "$config_file" ]; then
        # ИЗМЕНЕНИЕ: Исправлена переменная $config.env на $config_file
        success "Конфигурационный файл $config_file уже существует. Пропускаем создание."
    else
        log "Создание конфигурационного файла: $config_file"
        cat > "$config_file" << 'EOF'
# Конфигурация WhisperX
# HuggingFace токен для диаризации (получите на https://huggingface.co/settings/tokens)
# ВАЖНО: Примите лицензии на:
# https://huggingface.co/pyannote/speaker-diarization-3.1
# https://huggingface.co/pyannote/segmentation-3.0
HF_TOKEN=your_token_here

# Модель Whisper (tiny, base, small, medium, large-v1, large-v2, large-v3)
WHISPER_MODEL=large-v3

# Язык аудио (ru, en, auto для автоопределения)
LANGUAGE=ru

# Размер батча (чем больше - тем быстрее, но больше памяти GPU)
BATCH_SIZE=16

# Устройство для вычислений (cuda или cpu)
DEVICE=cuda

# Включить диаризацию (разделение по спикерам)
ENABLE_DIARIZATION=true

# Минимальное количество спикеров (оставить пустым для автоопределения)
MIN_SPEAKERS=

# Максимальное количество спикеров (оставить пустым для автоопределения)  
MAX_SPEAKERS=

# Тип вычислений (float16, float32, int8)
COMPUTE_TYPE=float16

# Метод VAD для обнаружения речи (pyannote, silero)
VAD_METHOD=pyannote

# Размер чанков в секундах
CHUNK_SIZE=30
EOF
        success "Конфигурационный файл создан: $config_file"
    fi
}

final_check() {
    log "Выполнение финальной проверки установки..."
    
    if ! command -v docker &>/dev/null; then error "Docker не найден!"; exit 1; fi
    if ! sudo docker image inspect "ghcr.io/jim60105/whisperx:latest" &>/dev/null; then error "Образ WhisperX не найден!"; exit 1; fi
    if ! [ -d "./audio" ]; then error "Рабочая директория не найдена!"; exit 1; fi
    if ! [ -d "$HOME/whisperx" ]; then error "Директория кеша моделей не найдена!"; exit 1; fi
    
    success "Все компоненты установлены и готовы к работе!"
}

show_usage() {
    printf "\n=====================================================================\n"
    printf "🎉 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!\n"
    printf "=====================================================================\n\n"
    
    printf "🔥 ВАЖНЫЕ СЛЕДУЮЩИЕ ШАГИ:\n\n"
    
    printf "1. 🔑 ${YELLOW}Отредактируйте токен Hugging Face${NC} для диаризации:\n"
    printf "   - Откройте файл: nano ./config.env\n"
    printf "   - Замените 'your_token_here' на ваш токен с https://huggingface.co/settings/tokens\n\n"

    printf "2. 🔄 ${YELLOW}Перезагрузите систему${NC}, если вы не были в группе docker:\n"
    printf "   sudo reboot\n\n"
    
    printf "После перезагрузки:\n"
    printf "3. 📁 Скопируйте ваши аудиофайлы в ./audio/\n"
    printf "4. 🚀 Запустите обработку: python3 whisperx_diarization.py\n\n"
    
    printf "Рабочие директории:\n"
    printf "  📂 ./audio      - Входные файлы (*.wav, *.mp3, *.m4a)\n"
    printf "  📂 ./results    - Результаты распознавания\n"
    printf "  🧠 ~/whisperx/  - Кеш моделей (общий для всех проектов)\n"
    printf "  ⚙️  ./config.env - Настройки\n\n"
    
    printf "=====================================================================\n"
}

# --- Основная функция ---
main() {
    printf "=====================================================================\n"
    printf "🎙️ УСТАНОВКА WHISPERX ДЛЯ ДИАРИЗАЦИИ РЕЧИ (DOCKER + NVIDIA)\n"
    printf "=====================================================================\n\n"
    
    check_distro
    check_gpu
    install_docker
    install_nvidia_toolkit
    
    if test_docker_gpu; then
      log "Тест GPU пройден. WhisperX будет использовать видеокарту."
    else
      warning "Тест GPU не пройден. Проверьте настройки в './config.env' и установите DEVICE=cpu, если GPU не заработает."
    fi

    pull_whisperx_image
    setup_workspace
    final_check
    show_usage
}

# Запуск основной функции
main