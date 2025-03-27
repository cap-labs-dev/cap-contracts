#!/bin/bash
set -e  # Exit on error

# Number of parallel jobs
DEFAULT_PARALLEL_JOBS=8
DOCKER_IMAGE="cap-mutant-test"
PROJECT_ROOT=$(pwd)
FOUNDRY_CACHE="$HOME/.foundry/cache"
GAMBIT_OUTDIR="$PWD/.gambit"

# derive some directories from this config
MUTANT_DIR="$GAMBIT_OUTDIR/mutants"
RESULTS_DIR="$GAMBIT_OUTDIR/mutant_results"
DOCKERFILE="$PROJECT_ROOT/test/mutation/Dockerfile.mutant-test"

# Check if required tools are available
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: Docker is not installed or not in PATH"
    exit 1
fi

# Check if gambit is installed
if ! command -v gambit >/dev/null 2>&1; then
    echo "Error: gambit is not installed. Please install it first:"
    echo "  - https://github.com/Certora/gambit"
    exit 1
fi

# Check if solc is installed
if ! command -v solc >/dev/null 2>&1; then
    echo "Error: solc is not installed. Please install it first:"
    echo "  - https://github.com/ethereum/solc-bin"
    echo "  - solc-select use 0.8.28"
    exit 1
fi

# Check if parallel is installed
if ! command -v parallel >/dev/null 2>&1; then
    echo "Error: GNU Parallel is not installed. Please install it first:"
    echo "  - On macOS: brew install parallel"
    echo "  - On Ubuntu/Debian: sudo apt-get install parallel"
    echo "  - On CentOS/RHEL: sudo yum install parallel"
    echo "  - On Alpine: apk add parallel"
    exit 1
fi

generate_mutants() {
    echo "Generating mutants..."
    local remappings=$(cat remappings.txt | tr '\n' ' ')
    echo $PROJECT_ROOT/gambit.config.json
    echo $PWD

    gambit mutate --json $PROJECT_ROOT/gambit.config.json
}

build_runner_docker_image() {
    # Build the Docker image first
    echo "Building Docker image for testing..."
    if ! docker build -t "$DOCKER_IMAGE" -f "$DOCKERFILE" --build-context foundry_cache="$FOUNDRY_CACHE" $PROJECT_ROOT; then
        echo "Error: Docker build failed"
        exit 1
    fi
}

# Check if a mutant has survived
# Returns 1 if the mutant has survived or not found, 0 otherwise
has_mutant_survived() {
    local mutant_num=$1
    local result_file="$RESULTS_DIR/$mutant_num"
    if [ ! -f "$result_file" ]; then
        return 0
    fi
    result=$(<"$result_file")
    if [[ "$result" != *"KILLED"* ]]; then
        return 0
    else
        return 1
    fi
}


list_surviving_mutants_nums() {
    # Find all mutant directories
    mutant_dirs=$(ls $MUTANT_DIR)

    # Check if any mutants exist
    if [ ${#mutant_dirs[@]} -eq 0 ]; then
        echo "Error: No mutant directories found in $MUTANT_DIR"
        exit 1
    fi

    # Filter out already killed mutants
    filtered_mutants=""
    for mutant in ${mutant_dirs[@]}; do
        if has_mutant_survived "$mutant"; then
            filtered_mutants="$filtered_mutants $mutant"
        fi
    done

    echo "$filtered_mutants"
}

# Function to test a single mutant
test_mutant() {
    local mutant_num=$1
    echo "========== test_mutant $mutant_num ==========="
    local mutant_dir="$MUTANT_DIR/$mutant_num"
    local result_file="$RESULTS_DIR/$mutant_num"
    echo "Mutant dir: $mutant_dir"
    echo "Result file: $result_file"

    # Run the test in Docker with the mutant mounted
    docker run --rm \
        -v "${mutant_dir}/contracts:/mutant:ro" \
        "$DOCKER_IMAGE" > "$result_file" 2>&1
    exit_code=$?
    
    echo "RESULT: $exit_code"

    if [ $exit_code -eq 0 ]; then
        # If tests pass, the mutant survived (bad)
        echo "⚠️  Mutant $mutant_num SURVIVED (tests passed) - potential test coverage gap!"
        echo "SURVIVED" > "$result_file"
    else
        # If tests fail, the mutant was killed (good)
        echo "✅ Mutant $mutant_num was killed (tests failed) - good!"
        echo "KILLED" > "$result_file"
    fi
}

# Run tests in parallel
export -f test_mutant

execute_mutant_tests_parallel() {
    local parallel_jobs=${1:-$DEFAULT_PARALLEL_JOBS}
    build_runner_docker_image

    # Counters for mutants
    total=0
    killed=0
    survived=0

    # Create a temporary directory for results
    if ! mkdir -p "$RESULTS_DIR"; then
        echo "Error: Failed to create results directory"
        exit 1
    fi

    local filtered_mutants=$(list_surviving_mutants_nums)
    if [ -z "$filtered_mutants" ]; then
        echo "No new mutants to test - all existing mutants were already killed"
        exit 0
    fi

    echo "Running mutation tests in parallel with $parallel_jobs jobs..."
    echo "$filtered_mutants" | tr ' ' '\n' | parallel -j "$parallel_jobs" --line-buffer "MUTANT_DIR='$MUTANT_DIR' DOCKER_IMAGE='$DOCKER_IMAGE' RESULTS_DIR='$RESULTS_DIR' test_mutant {}"

    # Check if any result files exist
    if ! ls "$RESULTS_DIR"/* >/dev/null 2>&1; then
        echo "Error: No test results found"
        exit 1
    fi

    # Count results
    for result in "$RESULTS_DIR"/*; do
        ((total++))
        if has_mutant_survived "$result"; then
            ((survived++))
        else
            ((killed++))
        fi
    done

    # Print summary
    echo ""
    echo "Mutation Testing Complete!"
    echo "------------------------"
    echo "Total mutants tested: $total"
    echo "Killed mutants (good): $killed"
    echo "Surviving mutants (test gaps): $survived"
    if [ "$total" -gt 0 ]; then
        echo "Kill rate: $(( (killed * 100) / total ))%"
    else
        echo "Kill rate: N/A (no mutants tested)"
    fi
    echo ""
    echo "The remaining mutants in $MUTANT_DIR are the ones that survived (test gaps)" 
}

clear_results() {
    echo "Clearing results..."
    rm -rf "$RESULTS_DIR"/*
}

diff_mutants() {
    gambit summary --mutation-directory $GAMBIT_OUTDIR --mids $(list_surviving_mutants_nums)
}

print_stats() {
    local total_mutants=$(ls $MUTANT_DIR | wc -w | tr -d ' ')
    local surviving_mutants=$(list_surviving_mutants_nums | wc -w | tr -d ' ')
    local surviving_mutants_percentage=$(( (surviving_mutants * 100) / total_mutants ))
    local killed_mutants=$((total_mutants - surviving_mutants))
    local kill_rate=$(( (killed_mutants * 100) / total_mutants ))
    local kill_rate_percentage=$(( (killed_mutants * 100) / total_mutants ))
    echo "Stats:"
    echo "  Total:     $total_mutants"
    echo "  Surviving: $surviving_mutants ($surviving_mutants_percentage%)"
    echo "  Killed:    $killed_mutants ($kill_rate_percentage%)"
}

test_baseline() {
    echo "Running baseline tests outside docker..."
    forge test --no-match-path 'test/**/*.invariants.t.sol' --fail-fast

    build_runner_docker_image
    echo "Running baseline tests in docker..."
    docker run --rm -v "$PROJECT_ROOT:/mutant:ro" --entrypoint /bin/bash "$DOCKER_IMAGE" -c "forge test --no-match-path 'test/**/*.invariants.t.sol' --fail-fast"
}

help() {
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Example:"
    echo "  $0 test 4"
    echo "  $0 survivors"
    echo "  $0 diff"
    echo "  $0 clear_results"
    echo "  $0 baseline"
    echo "Commands:"
    echo "  generate: Generate mutants"
    echo "  test: Run tests on surviving mutants (default $DEFAULT_PARALLEL_JOBS jobs)"
    echo ""
    echo "Helpers:"
    echo "  baseline: Run baseline tests (no mutants)"
    echo "  build: Build the Docker image"
    echo "  clear_results: Clear results to re-run tests"
    echo "  diff: Diff surviving mutants to find out gaps in the test suite"
    echo "  survivors: List surviving mutants"
    echo "  help: Show this help"
}

case $1 in
    "generate")
        generate_mutants
        ;;
    "build")
        build_runner_docker_image
        ;;
    "baseline")
        test_baseline
        ;;
    "test")
        execute_mutant_tests_parallel "$2"
        ;;
    "clear_results")
        clear_results
        ;;
    "diff")
        diff_mutants
        ;;
    "stats")
        print_stats
        ;;
    "survivors")
        list_surviving_mutants_nums
        ;;
    "help")
        help
        ;;
    *)
        echo "Error: Invalid command"
        help
        ;;
esac