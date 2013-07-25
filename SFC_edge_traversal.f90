! Sam(oa)² - SFCs and Adaptive Meshes for Oceanic And Other Applications
! Copyright (C) 2010 Oliver Meister, Kaveh Rahnema
! This program is licensed under the GPL, for details see the file LICENSE


!*****************************************************************
! MODULE SFC_edge_traversal: initialize edge data structures from an SFC_grid
!*****************************************************************
#include "Compilation_control.f90"

#include "Tools_grid.f90"

module SFC_edge_traversal
	use SFC_fine_grid
	use Grid
	use Grid_section

	implicit none

	public

    interface
        function op_edge_merge(local_edge, neighbor_edge) result(l_conform)
            import
            type(t_edge_data), intent(inout)    :: local_edge
            type(t_edge_data), intent(in)       :: neighbor_edge
            logical                             :: l_conform
        end function

        function op_node_merge(local_node, neighbor_node) result(l_conform)
            import
            type(t_node_data), intent(inout)    :: local_node
            type(t_node_data), intent(in)       :: neighbor_node
            logical                             :: l_conform
        end function
    end interface

	contains

	!*******************
	!create splitting
	!*******************

	subroutine rebalance_grid(src_grid, dest_grid)
		type(t_grid), intent(inout)                             :: src_grid
		type(t_grid), intent(inout)           	                :: dest_grid

		integer, parameter                                      :: min_section_size = 4
		integer                                                 :: i_first_src_section, i_last_src_section
		integer                                                 :: i_first_dest_section, i_last_dest_section
		type(t_grid_section), pointer                           :: section
		type(t_section_info_list), save                         :: section_descs

		integer (kind = GRID_DI)                                :: i_section, i_section_2, i_sections, overlap

        _log_write(4, '(3X, A)') "create splitting"

        !$omp single
        i_sections = min(src_grid%i_sections_per_thread * omp_get_num_threads(), src_grid%dest_cells / min_section_size)

        if (src_grid%dest_cells > 0) then
            i_sections = max(1, i_sections)
        end if

        _log_write(4, '(3X, A, I0)') "sections: ", i_sections
        call section_descs%resize(int(i_sections, GRID_SI))

        call prefix_sum(src_grid%sections%elements_alloc%last_dest_cell, src_grid%sections%elements_alloc%dest_cells)

        do i_section = 1, i_sections
            !Instead of rounding up the number of cells per section by using ceil(i_cells / i_sections),
            !set it to the difference of partial sums (i * i_cells) / i_sections - ((i - 1) * i_cells) / i_sections instead.
            !This guarantees, that there are exactly i_cells cells in total.

            !Add +4 to create enough space for additional refinement cells
			!64bit arithmetics are needed here, (i * i_cells) can become very big!
            section_descs%elements(i_section)%index = i_section
            section_descs%elements(i_section)%i_cells = (i_section * src_grid%dest_cells) / i_sections - ((i_section - 1_GRID_DI) * src_grid%dest_cells) / i_sections + 4
            section_descs%elements(i_section)%i_stack_nodes = src_grid%max_dest_stack - src_grid%min_dest_stack + 1
            section_descs%elements(i_section)%i_stack_edges = src_grid%max_dest_stack - src_grid%min_dest_stack + 1

            call section_descs%elements(i_section)%estimate_bounds()
            _log_write(4, '(4X, I0)') section_descs%elements(i_section)%i_cells - 4
        end do
        !$omp end single copyprivate(i_sections)

        !create new grid
        call dest_grid%create(section_descs, src_grid%max_dest_stack - src_grid%min_dest_stack + 1)

        call src_grid%get_local_sections(i_first_src_section, i_last_src_section)
        call dest_grid%get_local_sections(i_first_dest_section, i_last_dest_section)

        do i_section = i_first_dest_section, i_last_dest_section
            section => dest_grid%sections%elements_alloc(i_section)

            section%t_global_data = src_grid%t_global_data
            section%dest_cells = size(section%cells%elements) - 4
            section%load = 0.0_GRID_SR
        end do

        !$omp barrier

        !copy load estimate from old grid
        do i_section = i_first_src_section, i_last_src_section
            section => src_grid%sections%elements_alloc(i_section)

            i_first_dest_section = 1 + ((section%last_dest_cell - section%dest_cells + 1) * i_sections - 1) / src_grid%dest_cells
            i_last_dest_section = 1 + (section%last_dest_cell * i_sections - 1) / src_grid%dest_cells

            do i_section_2 = i_first_dest_section, i_last_dest_section
                !determine overlap
                overlap = min(section%last_dest_cell, (i_section_2 * src_grid%dest_cells) / i_sections) - max(section%last_dest_cell - section%dest_cells, ((i_section_2 - 1_GRID_DI)  * src_grid%dest_cells) / i_sections)
                assert_gt(overlap, 0)
                assert_le(overlap, section%dest_cells)

                !$omp atomic
                dest_grid%sections%elements_alloc(i_section_2)%load = dest_grid%sections%elements_alloc(i_section_2)%load + (section%load * overlap) / section%dest_cells
            end do
        end do

        !$omp single
            dest_grid%stats = src_grid%stats
            dest_grid%t_global_data = src_grid%t_global_data
        !$omp end single
    end subroutine

    subroutine update_distances(grid)
        type(t_grid), intent(inout)						:: grid
        integer (kind = GRID_SI)                        :: i_section, i_first_local_section, i_last_local_section, i_color
        type(t_grid_section), pointer					:: section
        integer (kind = GRID_DI)                        :: min_distances(RED : GREEN)

        _log_write(3, '(3X, A)') "update distances:"

        _log_write(4, '(4X, A)') "grid distances (before):"
        _log_write(4, '(5X, A, 2(F0.4, X))') "start:", decode_distance(grid%start_distance)
        _log_write(4, '(5X, A, 2(F0.4, X))') "min  :", decode_distance(grid%min_distance)
        _log_write(4, '(5X, A, 2(F0.4, X))') "end  :", decode_distance(grid%end_distance)

        call grid%get_local_sections(i_first_local_section, i_last_local_section)

        _log_write(4, '(4X, A)') "section distances (not matched):"
        do i_section = i_first_local_section, i_last_local_section
            section => grid%sections%elements_alloc(i_section)
            _log_write(4, '(5X, A, I0)') "section:", i_section

            _log_write(4, '(6X, A, 2(F0.4, X))') "start:", decode_distance(section%start_distance)
            _log_write(4, '(6X, A, 2(F0.4, X))') "min  :", decode_distance(section%min_distance)
            _log_write(4, '(6X, A, 2(F0.4, X))') "end  :", decode_distance(section%end_distance)

            section%min_distance = section%min_distance - section%start_distance
            section%end_distance = section%end_distance - section%start_distance
            section%start_distance = section%end_distance
        end do

        !$omp barrier

        !$omp single
        if (size(grid%sections%elements) > 0) then
            call prefix_sum(grid%sections%elements%end_distance(RED), grid%sections%elements%end_distance(RED))
            call prefix_sum(grid%sections%elements%end_distance(GREEN), grid%sections%elements%end_distance(GREEN))
        end if
        !$omp end single

        do i_section = i_first_local_section, i_last_local_section
            section => grid%sections%elements_alloc(i_section)

            section%min_distance = section%min_distance + section%end_distance - section%start_distance
            section%start_distance = section%end_distance - section%start_distance
        end do

        !$omp barrier

        !$omp single
        min_distances(RED) = grid%min_distance(RED) - minval(grid%sections%elements%min_distance(RED))
        min_distances(GREEN) = grid%min_distance(GREEN) - minval(grid%sections%elements%min_distance(GREEN))
        !$omp end single copyprivate(min_distances)

        _log_write(4, '(4X, A)') "section distances (matched):"
        do i_section = i_first_local_section, i_last_local_section
            section => grid%sections%elements_alloc(i_section)

            _log_write(4, '(5X, A, I0)') "section: ", i_section

            section%min_distance = section%min_distance + min_distances
            section%start_distance = section%start_distance + min_distances
            section%end_distance = section%end_distance + min_distances

            do i_color = RED, GREEN
                section%boundary_edges(i_color)%elements%min_distance = section%boundary_edges(i_color)%elements%min_distance + section%min_distance(i_color)
                section%boundary_nodes(i_color)%elements%distance = section%boundary_nodes(i_color)%elements%distance + section%min_distance(i_color)
            end do

            _log_write(4, '(6X, A, 2(F0.4, X))') "start:", decode_distance(section%start_distance)
            _log_write(4, '(6X, A, 2(F0.4, X))') "min  :", decode_distance(section%min_distance)
            _log_write(4, '(6X, A, 2(F0.4, X))') "end  :", decode_distance(section%end_distance)
        end do

        !$omp barrier

        !$omp single
        if (size(grid%sections%elements) > 0) then
            grid%start_distance = grid%sections%elements(1)%start_distance
            grid%end_distance = grid%sections%elements(size(grid%sections%elements))%end_distance
        end if

        _log_write(4, '(4X, A)') "grid distances (after):"
        _log_write(4, '(5X, A, 2(F0.4, X))') "start:", decode_distance(grid%start_distance)
        _log_write(4, '(5X, A, 2(F0.4, X))') "min  :", decode_distance(grid%min_distance)
        _log_write(4, '(5X, A, 2(F0.4, X))') "end  :", decode_distance(grid%end_distance)
        !$omp end single
    end subroutine

	!*******************
	!update neighbors
	!*******************

    subroutine update_neighbors(src_grid, dest_grid)
        type(t_grid), intent(in)						:: src_grid
        type(t_grid), intent(inout)						:: dest_grid

        integer(kind = GRID_DI), save, allocatable      :: neighbor_min_distances_red(:, :), neighbor_min_distances_green(:, :)
        type(t_integer_list), save                      :: src_neighbor_list_red, src_neighbor_list_green
        integer                                         :: i_error

        _log_write(4, '(X, A)') "update neighbors:"

        !$omp single
        src_neighbor_list_red = t_integer_list()
        src_neighbor_list_green = t_integer_list()

        !find all source grid neighbors
        call get_grid_neighbors(src_grid, src_neighbor_list_red, RED)
        call get_grid_neighbors(src_grid, src_neighbor_list_green, GREEN)

        !collect minimum distances
        call collect_minimum_distances(dest_grid, src_neighbor_list_red, neighbor_min_distances_red, RED)
        call collect_minimum_distances(dest_grid, src_neighbor_list_green, neighbor_min_distances_green, GREEN)
        !$omp end single

        !barrier here, all destination sections must have found their boundary elements in order to continue

        !find all destination grid neighbors by checking if any overlap between local sections and neighbors exists
        call create_dest_neighbor_lists(dest_grid, src_neighbor_list_red, src_neighbor_list_green, neighbor_min_distances_red, neighbor_min_distances_green)

        !$omp single
#		if defined(_MPI)
        	deallocate(neighbor_min_distances_red, stat = i_error); assert_eq(i_error, 0)
        	deallocate(neighbor_min_distances_green, stat = i_error); assert_eq(i_error, 0)
#		endif

        call src_neighbor_list_red%clear()
        call src_neighbor_list_green%clear()
        !$omp end single
    end subroutine

    subroutine get_grid_neighbors(grid, rank_list, i_color)
        type(t_grid), intent(in)						:: grid
        type(t_integer_list), intent(out)               :: rank_list
        integer (KIND = 1), intent(in)			        :: i_color

        type(t_grid_section), pointer                   :: section
        type(t_comm_interface), pointer                 :: comm
        integer (kind = GRID_SI)			            :: i_section, i_comm

        _log_write(4, '(3X, A, A)') "get neighbors: ", trim(color_to_char(i_color))

        do i_section = 1, size(grid%sections%elements)
            section => grid%sections%elements(i_section)

            _log_write(4, '(5X, A, I0)') "section:", i_section

            do i_comm = 1, size(section%comms(i_color)%elements)
                comm => section%comms(i_color)%elements(i_comm)

                _log_write(4, '(6X, A, I0)') "comm: ", comm%neighbor_rank

                if (comm%neighbor_rank .ge. 0 .and. comm%neighbor_rank .ne. rank_MPI) then
                    if (size(rank_list%elements) .eq. 0) then
                        call rank_list%add(comm%neighbor_rank)
                        _log_write(4, '(7X, A)') "added (because list is empty)"
                    else if (.not. any(rank_list%elements .eq. comm%neighbor_rank)) then
                        call rank_list%add(comm%neighbor_rank)
                        _log_write(4, '(7X, A)') "added (because not in list)"
                    end if
                end if
            end do
        end do

        if (.not. grid%sections%is_forward()) then
            call rank_list%reverse()
        end if

        _log_write(4, '(4X, A, I0, 1X, I0)') "#neighbors: ", size(rank_list%elements)
    end subroutine

    subroutine collect_minimum_distances(grid, rank_list, neighbor_min_distances, i_color)
        type(t_grid), intent(inout)						    :: grid
        type(t_integer_list), intent(inout)                 :: rank_list
        integer(kind = GRID_DI), allocatable, intent(out)   :: neighbor_min_distances(:, :)
        integer (kind = 1), intent(in)				        :: i_color

        integer(kind = GRID_DI), allocatable                :: local_min_distances(:)
        integer, allocatable							    :: requests(:, :), i_neighbor_sections(:)
        integer											    :: i_comm, i_neighbors, i_section, i_error, i_sections, i_max_sections

        !Collect minimum distances from all sections oif all neighbor processes
        _log_write(3, '(3X, A, A)') "collect minimum distances from sections: ", trim(color_to_char(i_color))

#		if defined(_MPI)
            i_sections = size(grid%sections%elements_alloc)
            i_max_sections = omp_get_num_threads() * grid%i_sections_per_thread * 2
            i_neighbors = size(rank_list%elements)
            assert_le(i_sections, i_max_sections)

		   	allocate(i_neighbor_sections(i_neighbors), stat = i_error); assert_eq(i_error, 0)
		   	allocate(requests(i_neighbors, 2), stat = i_error); assert_eq(i_error, 0)
		    requests = MPI_REQUEST_NULL

            allocate(local_min_distances(i_sections), stat = i_error); assert_eq(i_error, 0)
            local_min_distances = grid%sections%elements_alloc%min_distance(i_color)

            _log_write(4, '(4X, A, I0, A)') "rank: ", rank_MPI, " (local)"
            do i_section = 1, i_sections
                _log_write(4, '(5X, A, I0, A, F0.4)') "local section ", i_section, " distance: ", decode_distance(local_min_distances(i_section))
            end do

            allocate(neighbor_min_distances(i_max_sections, i_neighbors), stat = i_error); assert_eq(i_error, 0)
            neighbor_min_distances = huge(1_GRID_DI)

            !send/receive number of sections

            assert_veq(requests, MPI_REQUEST_NULL)

		    do i_comm = 1, i_neighbors
                call mpi_isend(i_sections, 1, MPI_INTEGER, rank_list%elements(i_comm), 0, MPI_COMM_WORLD, requests(i_comm, 1), i_error); assert_eq(i_error, 0)
                call mpi_irecv(i_neighbor_sections(i_comm), 1, MPI_INTEGER, rank_list%elements(i_comm), 0, MPI_COMM_WORLD, requests(i_comm, 2), i_error); assert_eq(i_error, 0)
 		    end do

            call mpi_waitall(2 * i_neighbors, requests, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)

            requests = MPI_REQUEST_NULL

            !send/receive distances

            assert_veq(requests, MPI_REQUEST_NULL)

		    do i_comm = 1, i_neighbors
                call mpi_isend(local_min_distances(1), sizeof(local_min_distances), MPI_BYTE, rank_list%elements(i_comm), 0, MPI_COMM_WORLD, requests(i_comm, 1), i_error); assert_eq(i_error, 0)
                call mpi_irecv(neighbor_min_distances(1, i_comm), i_neighbor_sections(i_comm) * sizeof(neighbor_min_distances(1, i_comm)), MPI_BYTE, rank_list%elements(i_comm), 0, MPI_COMM_WORLD, requests(i_comm, 2), i_error); assert_eq(i_error, 0)
 		    end do

            call mpi_waitall(2 * i_neighbors, requests, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)

            requests = MPI_REQUEST_NULL

            do i_comm = 1, i_neighbors
                _log_write(4, '(4X, A, I0)') "rank: ", rank_list%elements(i_comm)
                do i_section = 1, i_neighbor_sections(i_comm)
                    _log_write(4, '(5X, A, I0, A, F0.4)') "section: ", i_section, " , distance: ", decode_distance(neighbor_min_distances(i_section, i_comm))
                end do
            end do

        	deallocate(requests, stat = i_error); assert_eq(i_error, 0)
        	deallocate(i_neighbor_sections, stat = i_error); assert_eq(i_error, 0)
        	deallocate(local_min_distances, stat = i_error); assert_eq(i_error, 0)
#		endif
    end subroutine

    subroutine create_dest_neighbor_lists(grid, src_neighbor_list_red, src_neighbor_list_green, neighbor_min_distances_red, neighbor_min_distances_green)
        type(t_grid), intent(inout)						:: grid
        type(t_integer_list), intent(in)                :: src_neighbor_list_red, src_neighbor_list_green
        integer (KIND = GRID_DI), intent(in)            :: neighbor_min_distances_red(:, :), neighbor_min_distances_green(:, :)

        integer (KIND = GRID_SI)			            :: i_section, i_first_local_section, i_last_local_section
        integer (KIND = 1)			                    :: i_color
        type(t_grid_section), pointer					:: section

        _log_write(4, '(3X, A, I0, X, I0)') "create destination comm list: #neighbors: ", size(src_neighbor_list_red%elements), size(src_neighbor_list_red%elements)

        call grid%get_local_sections(i_first_local_section, i_last_local_section)

        do i_section = i_first_local_section, i_last_local_section
            section => grid%sections%elements_alloc(i_section)

            call set_comms_local_data(grid, section, src_neighbor_list_red, neighbor_min_distances_red, RED)
            call set_comms_local_data(grid, section, src_neighbor_list_green, neighbor_min_distances_green, GREEN)
        end do

        !$omp barrier

        do i_section = i_first_local_section, i_last_local_section
            section => grid%sections%elements_alloc(i_section)

            _log_write(4, '(4X, A, I0)') "section set neighbor pointers: ", i_section

            do i_color = RED, GREEN
                call set_comm_neighbor_data(grid, section, i_color)
            end do
        end do
    end subroutine

    subroutine set_comms_local_data(grid, section, src_neighbor_list, neighbor_min_distances, i_color)
        type(t_grid), intent(inout)						:: grid
        type(t_grid_section), pointer, intent(inout)    :: section
        type(t_integer_list), intent(in)                :: src_neighbor_list
        integer (KIND = GRID_DI), intent(in)            :: neighbor_min_distances(:,:)
        integer (KIND = 1), intent(in)			        :: i_color

        integer                                         :: i_comm

        _log_write(4, '(4X, A, I0)') "set local data: section ", section%index

        call find_section_neighbors(grid, section, src_neighbor_list, neighbor_min_distances, i_color)

        !count number of boundary elements shared with each comm and set the owner of each element
        call count_section_boundary_elements(section, i_color)
        call set_comm_local_pointers(section, i_color)

        !test for correctness
        assert_eq(sum(section%comms(i_color)%elements%i_edges), size(section%boundary_edges(i_color)%elements))
        assert_eq(sum(max(section%comms(i_color)%elements%i_nodes - 1, 0)) + 1, size(section%boundary_nodes(i_color)%elements))

        _log_write(4, '(5X, A, A, A)') "Neighbors (", trim(color_to_char(i_color)), "):"
        do i_comm = 1, size(section%comms(i_color)%elements)
            _log_write(4, '(6X, (A))') trim(section%comms(i_color)%elements(i_comm)%to_string())
        end do
    end subroutine

    subroutine find_section_neighbors(grid, section, src_neighbor_list, neighbor_min_distances, i_color)
        type(t_grid), intent(inout)						:: grid
        type(t_grid_section), pointer , intent(inout)	:: section
        type(t_integer_list), intent(in)                :: src_neighbor_list
        integer(kind = GRID_DI), intent(in)             :: neighbor_min_distances(:, :)
        integer (KIND = 1), intent(in)			        :: i_color

        integer (KIND = GRID_SI)						:: i_comm, i_section_2, i_max_sections, i_comms_old, i_comms_new
        integer (KIND = GRID_DI)                        :: min_distance, max_distance
        type(t_grid_section), pointer                   :: section_2

        min_distance = section%min_distance(i_color)
        i_max_sections = omp_get_num_threads() * grid%i_sections_per_thread * 2

        !clear comm list if it is not empty
        assert(.not. associated(section%comms(i_color)%elements) .or. size(section%comms(i_color)%elements) .eq. 0)
        section%comms_type(OLD, i_color)%elements => null()
        section%comms_type(NEW, i_color)%elements => null()

        !first, iterate over old boundary
        max_distance = max(section%start_distance(i_color), section%end_distance(i_color))

        !first, check local sections
        do i_section_2 = section%index - 1, 1, -1
            section_2 => grid%sections%elements_alloc(i_section_2)

            if (max_distance < min_distance) then
                exit
            end if

            assert_eq(i_section_2, section_2%index)

            if (section_2%min_distance(i_color) .le. max_distance) then
                call section%comms_type(OLD, i_color)%add(t_comm_interface(local_rank = rank_MPI, neighbor_rank = rank_MPI, local_section = section%index, neighbor_section = i_section_2, min_distance = section_2%min_distance(i_color)))
                max_distance = section_2%min_distance(i_color)
            end if
        end do

        !next, check process neighbors
        do i_comm = 1, size(src_neighbor_list%elements)
            if (max_distance < min_distance .or. src_neighbor_list%elements(i_comm) > rank_MPI) then
                exit
            end if

            do i_section_2 = i_max_sections, 1, -1
                if (max_distance < min_distance) then
                    exit
                end if

                if (neighbor_min_distances(i_section_2, i_comm) .le. max_distance) then
                    call section%comms_type(OLD, i_color)%add(t_comm_interface(local_rank = rank_MPI, neighbor_rank = src_neighbor_list%elements(i_comm), local_section = section%index, neighbor_section = i_section_2, min_distance = neighbor_min_distances(i_section_2, i_comm)))
                    max_distance = neighbor_min_distances(i_section_2, i_comm)
                end if
            end do
        end do

        !add a domain boundary comm and serialize comm list for faster access
        call section%comms_type(OLD, i_color)%add(t_comm_interface(local_rank = rank_MPI, neighbor_rank = -1, local_section = section%index, neighbor_section = -1, min_distance = -huge(1_GRID_DI)))

        !second, iterate over new boundary
        max_distance = max(section%start_distance(i_color), section%end_distance(i_color))

        !first, check local sections
        do i_section_2 = section%index + 1, size(grid%sections%elements_alloc)
            section_2 => grid%sections%elements_alloc(i_section_2)

            if (max_distance < min_distance) then
                exit
            end if

            assert_eq(i_section_2, section_2%index)

            if (section_2%min_distance(i_color) .le. max_distance) then
                call section%comms_type(NEW, i_color)%add(t_comm_interface(local_rank = rank_MPI, neighbor_rank = rank_MPI, local_section = section%index, neighbor_section = section_2%index, min_distance = section_2%min_distance(i_color)))
                max_distance = section_2%min_distance(i_color)
            end if
        end do

        !next, check process neighbors
        do i_comm = size(src_neighbor_list%elements), 1, -1
            if (max_distance < min_distance .or. src_neighbor_list%elements(i_comm) < rank_MPI) then
                exit
            end if

            do i_section_2 = 1, i_max_sections
                if (max_distance < min_distance) then
                    exit
                end if

                if (neighbor_min_distances(i_section_2, i_comm) .le. max_distance) then
                    call section%comms_type(NEW, i_color)%add(t_comm_interface(local_rank = rank_MPI, neighbor_rank = src_neighbor_list%elements(i_comm), local_section = section%index, neighbor_section = i_section_2, min_distance = neighbor_min_distances(i_section_2, i_comm)))
                    max_distance = neighbor_min_distances(i_section_2, i_comm)
                end if
            end do
        end do

        !add a domain boundary comm and serialize comm list for faster access
        call section%comms_type(NEW, i_color)%add(t_comm_interface(local_rank = rank_MPI, neighbor_rank = -1, local_section = section%index, neighbor_section = huge(1_GRID_SI), min_distance = -huge(1_GRID_DI)))

        !merge old and new comm lists (new list must be reversed first)
        call section%comms_type(NEW, i_color)%reverse()
        i_comms_old = size(section%comms_type(OLD, i_color)%elements)
        i_comms_new = size(section%comms_type(NEW, i_color)%elements)
        section%comms(i_color) = section%comms(i_color)%merge(section%comms_type(OLD, i_color), section%comms_type(NEW, i_color))

        call section%comms_type(OLD, i_color)%clear()
        call section%comms_type(NEW, i_color)%clear()

        if (grid%sections%is_forward()) then
            section%comms_type(OLD, i_color)%elements => section%comms(i_color)%elements(1 : i_comms_old)
            section%comms_type(NEW, i_color)%elements => section%comms(i_color)%elements(i_comms_old + 1 : )
        else
            call section%comms(i_color)%reverse()

            section%comms_type(OLD, i_color)%elements => section%comms(i_color)%elements(1 : i_comms_new)
            section%comms_type(NEW, i_color)%elements => section%comms(i_color)%elements(i_comms_new + 1 : )
        end if
    end subroutine

    subroutine count_section_boundary_elements(section, i_color)
        type(t_grid_section), intent(inout)				:: section
        integer (KIND = 1), intent(in)			        :: i_color

        integer (KIND = GRID_SI)                        :: i_current_edge, i_current_node, i_pass, i_comm
        type(t_edge_data), pointer                      :: current_edge
        type(t_node_data), pointer                      :: current_node
        type(t_comm_interface), pointer                 :: comm

        !match section boundaries with comm distances to find the number of edges and nodes
        !that each comm shares with each section

        _log_write(4, '(5X, A, I0)') "count section boundary elements: section ", section%index

        !reverse new neighbors in order to compare decreasing distances
        call section%boundary_type_edges(NEW, i_color)%reverse()
        call section%boundary_type_nodes(NEW, i_color)%reverse()
        call section%comms_type(NEW, i_color)%reverse()

        do i_pass = OLD, NEW
            _log_write(4, '(6X, A, A)') "pass: ", edge_type_to_char(i_pass)
            _log_write(4, '(7X, A)') "compare edges:"

            i_comm = 1
            assert_le(i_comm, size(section%comms_type(i_pass, i_color)%elements))
            comm => section%comms_type(i_pass, i_color)%elements(i_comm)

            _log_write(4, '(8X, A, A)') "nb: ", trim(comm%to_string())

            do i_current_edge = 1, size(section%boundary_type_edges(i_pass, i_color)%elements)
                current_edge => section%boundary_type_edges(i_pass, i_color)%elements(i_current_edge)

                do while (current_edge%min_distance .lt. comm%min_distance)
                    i_comm = i_comm + 1
                    assert_le(i_comm, size(section%comms_type(i_pass, i_color)%elements))
                    comm => section%comms_type(i_pass, i_color)%elements(i_comm)

                    _log_write(4, '(8X, A, A)') "nb: ", trim(comm%to_string())
                end do

                comm%i_edges = comm%i_edges + 1
                _log_write(4, '(8X, A, F0.4, X, F0.4)') "edge: ", decode_distance(current_edge%min_distance), decode_distance(current_edge%min_distance + encode_edge_size(current_edge%depth))
            end do

            _log_write(4, '(7X, A)') "compare nodes:"

            i_comm = 1
            assert_le(i_comm, size(section%comms_type(i_pass, i_color)%elements))
            comm => section%comms_type(i_pass, i_color)%elements(i_comm)

            _log_write(4, '(8X, A, A)') "nb  : ", trim(comm%to_string())

            do i_current_node = 1, size(section%boundary_type_nodes(i_pass, i_color)%elements)
                current_node => section%boundary_type_nodes(i_pass, i_color)%elements(i_current_node)

                do while (current_node%distance .lt. comm%min_distance)
                    i_comm = i_comm + 1
                    assert_le(i_comm, size(section%comms_type(i_pass, i_color)%elements))
                    comm => section%comms_type(i_pass, i_color)%elements(i_comm)

                    _log_write(4, '(8X, A, A)') "nb: ", trim(comm%to_string())
                end do

                do
                    comm%i_nodes = comm%i_nodes + 1
                    _log_write(4, '(8X, A, F0.4)') "node: ", decode_distance(current_node%distance)

                    if (current_node%distance .eq. comm%min_distance) then
                        i_comm = i_comm + 1
                        assert_le(i_comm, size(section%comms_type(i_pass, i_color)%elements))
                        comm => section%comms_type(i_pass, i_color)%elements(i_comm)

                        _log_write(4, '(8X, A, A)') "nb  : ", trim(comm%to_string())
                    else
                        exit
                    end if
                end do
            end do
        end do

        !restore the correct order by reversing again.
        call section%boundary_type_edges(NEW, i_color)%reverse()
        call section%boundary_type_nodes(NEW, i_color)%reverse()
        call section%comms_type(NEW, i_color)%reverse()
    end subroutine

    subroutine set_comm_local_pointers(section, i_color)
        type(t_grid_section), intent(inout)				:: section
        integer (KIND = 1), intent(in)			        :: i_color

        integer (KIND = GRID_SI)                        :: i_comm
        integer (KIND = GRID_SI)                        :: i_first_edge, i_first_node, i_last_edge, i_last_node
        logical                                         :: l_forward
        type(t_comm_interface), pointer                 :: comm

        _log_write(4, '(4X, A, I0)') "set local pointers: section ", section%index
        _log_write(4, '(4X, A, A, A)') "Neighbors (", trim(color_to_char(i_color)), "):"

        !set ownership to true initally and falsify each wrong entry afterwards
        section%boundary_edges(i_color)%elements%owned_locally = .true.
        section%boundary_edges(i_color)%elements%owned_globally = .true.
        section%boundary_nodes(i_color)%elements%owned_locally = .true.
        section%boundary_nodes(i_color)%elements%owned_globally = .true.

        i_first_edge = 0
        i_last_edge = 0
        i_first_node = 1
        i_last_node = 0

        l_forward = section%boundary_nodes(i_color)%is_forward()

        do i_comm = 1, size(section%comms(i_color)%elements)
            comm => section%comms(i_color)%elements(i_comm)

            _log_write(4, '(6X, (A))') trim(comm%to_string())

            assert_eq(comm%local_rank, rank_MPI)
            assert_eq(comm%local_section, section%index)

            i_first_edge = i_last_edge + 1
            i_first_node = max(i_first_node, i_last_node)
            i_last_edge = i_first_edge + comm%i_edges - 1
            i_last_node = i_first_node + comm%i_nodes - 1

            if (l_forward) then
                comm%p_local_edges => section%boundary_edges(i_color)%elements(i_first_edge : i_last_edge)
                comm%p_local_nodes => section%boundary_nodes(i_color)%elements(i_first_node : i_last_node)
            else
                comm%p_local_edges => section%boundary_edges(i_color)%elements(i_last_edge : i_first_edge : -1)
                comm%p_local_nodes => section%boundary_nodes(i_color)%elements(i_last_node : i_first_node : -1)
            end if

            !each entity with a neighbor of lower section index is not owned by the current section
            if (comm%neighbor_rank .ge. 0 .and. comm%neighbor_rank < rank_MPI) then
                comm%p_local_edges%owned_globally = .false.
                comm%p_local_nodes%owned_globally = .false.
            else if (comm%neighbor_rank == rank_MPI .and. comm%neighbor_section < section%index) then
                comm%p_local_edges%owned_locally = .false.
                comm%p_local_edges%owned_globally = .false.
                comm%p_local_nodes%owned_locally = .false.
                comm%p_local_nodes%owned_globally = .false.
            end if

            assert_eq(size(comm%p_local_edges), comm%i_edges)
            assert_eq(size(comm%p_local_nodes), comm%i_nodes)
        end do
    end subroutine

    function find_section_comm(comms, i_rank, i_section) result(comm)
        type(t_comm_interface), pointer, intent(in)         :: comms(:)
        type(t_comm_interface), pointer                     :: comm
        integer (kind = GRID_SI), intent(in)                :: i_rank
        integer (kind = GRID_SI), intent(in)                :: i_section
        logical                                             :: is_increasing

        integer (kind = GRID_SI)                            :: i_comm_start, i_comm_end, i_comm
        integer (kind = GRID_SI), parameter                 :: vector_threshold = 16 - 1

        !find the correct comm index

        !i_comm = minloc(abs(comms%neighbor_section - i_section), 1)

        !use binary search as long as the array is still big
        i_comm_start = 1
        i_comm_end = size(comms)

        is_increasing = ishft(comms(i_comm_end)%neighbor_rank, 16) + comms(i_comm_end)%neighbor_section > ishft(comms(i_comm_start)%neighbor_rank, 16) + comms(i_comm_start)%neighbor_section

        if (is_increasing) then
            do while (i_comm_end - i_comm_start > vector_threshold)
                i_comm = (i_comm_start + i_comm_end) / 2
                comm => comms(i_comm)

                select case(comm%neighbor_rank - i_rank)
                case (0)
                    select case(comm%neighbor_section - i_section)
                    case (0)
                        return
                    case(:-1)
                        i_comm_start = i_comm + 1
                    case(1:)
                        i_comm_end = i_comm - 1
                    end select
                case(:-1)
                    i_comm_start = i_comm + 1
                case(1:)
                    i_comm_end = i_comm - 1
                end select
            end do
        else
            do while (i_comm_end - i_comm_start > vector_threshold)
                i_comm = (i_comm_start + i_comm_end) / 2
                comm => comms(i_comm)

                select case(i_rank - comm%neighbor_rank)
                case (0)
                    select case(i_section - comm%neighbor_section)
                    case (0)
                        return
                    case(:-1)
                        i_comm_end = i_comm - 1
                    case(1:)
                        i_comm_start = i_comm + 1
                    end select
                case(:-1)
                    i_comm_end = i_comm - 1
                case(1:)
                    i_comm_start = i_comm + 1
                end select
            end do
        end if

        !switch to a linear search for small arrays
        i_comm = minloc(abs((ishft(comms(i_comm_start : i_comm_end)%neighbor_rank, 16) + comms(i_comm_start : i_comm_end)%neighbor_section) - (ishft(i_rank, 16) + i_section)), 1)
        comm => comms(i_comm)

        assert_eq(comm%neighbor_rank, i_rank)
        assert_eq(comm%neighbor_section, i_section)
    end function

    subroutine set_comm_neighbor_data(grid, section, i_color)
        type(t_grid), intent(inout)				        :: grid
        type(t_grid_section), pointer, intent(inout)	:: section
        integer (KIND = 1), intent(in)			        :: i_color

        integer (KIND = GRID_SI)                        :: i_comm, i_pass
        integer (KIND = GRID_SI)                        :: i_first_edge, i_first_node, i_last_edge, i_last_node
        type(t_comm_interface), pointer                 :: comm, comm_2
        type(t_grid_section), pointer				    :: section_2

        _log_write(4, '(4X, A, I0)') "set neighbor data: section ", section%index
        _log_write(4, '(4X, A, A, A)') "Neighbors (", trim(color_to_char(i_color)), "):"

        do i_pass = OLD, NEW
            _log_write(4, '(5X, A, A)') trim(edge_type_to_char(i_pass)), ":"

            do i_comm = 1, size(section%comms_type(i_pass, i_color)%elements)
                comm => section%comms_type(i_pass, i_color)%elements(i_comm)
                assert_eq(section%index, comm%local_section)

                _log_write(4, '(6X, (A))') trim(comm%to_string())

                assert_eq(comm%local_rank, rank_MPI)
                assert_eq(comm%local_section, section%index)

                if (comm%neighbor_rank == rank_MPI) then
                    section_2 => grid%sections%elements_alloc(comm%neighbor_section)
                    assert_eq(section_2%index, comm%neighbor_section)

                    comm_2 => find_section_comm(section_2%comms_type(1 - i_pass, i_color)%elements, rank_MPI, section%index)

                    assert_eq(comm%local_rank, comm_2%neighbor_rank)
                    assert_eq(comm%local_section, comm_2%neighbor_section)
                    assert_eq(comm_2%local_rank, comm%neighbor_rank)
                    assert_eq(comm_2%local_section, comm%neighbor_section)

                    comm%p_neighbor_edges => comm_2%p_local_edges
                    comm%p_neighbor_nodes => comm_2%p_local_nodes

                    assert_eq(comm%i_edges, comm_2%i_edges)
                    assert_eq(comm%i_nodes, comm_2%i_nodes)
                    assert_veq(decode_distance(comm%p_local_edges%min_distance), decode_distance(comm_2%p_local_edges(comm%i_edges : 1 : -1)%min_distance))
                    assert_veq(decode_distance(comm%p_local_nodes%distance), decode_distance(comm_2%p_local_nodes(comm%i_nodes : 1 : -1)%distance))
                else if (comm%neighbor_rank .ge. 0) then
                    call comm%create_buffer()

                    assert_eq(size(comm%p_neighbor_edges), comm%i_edges)
                    assert_eq(size(comm%p_neighbor_nodes), comm%i_nodes)
                end if
            end do
        end do
    end subroutine

    subroutine send_mpi_boundary(section)
        type(t_grid_section), intent(inout)				:: section

        integer (kind = GRID_SI)						:: i_comm
        integer                                         :: i_error, send_tag, recv_tag
        integer (kind = 1)							    :: i_color
        type(t_comm_interface), pointer			        :: comm

        _log_write(4, '(4X, A, I0)') "send mpi boundary: section ", section%index

#        if defined(_MPI)
             do i_color = RED, GREEN
                _log_write(4, '(5X, A, A)') trim(color_to_char(i_color)), ":"

                do i_comm = 1, size(section%comms(i_color)%elements)
                    comm => section%comms(i_color)%elements(i_comm)

                    assert(associated(comm%p_local_edges))
                    assert(associated(comm%p_local_nodes))

                    if (comm%neighbor_rank .ge. 0 .and. comm%neighbor_rank .ne. rank_MPI) then
                        _log_write(4, '(6X, A)') trim(comm%to_string())
                        assert(associated(comm%p_neighbor_edges))
                        assert(associated(comm%p_neighbor_nodes))

                        send_tag = ishft(comm%local_section, 16) + comm%neighbor_section
                        recv_tag = ishft(comm%neighbor_section, 16) + comm%local_section

                        _log_write(5, '(7X, A, I0, X, I0, A, I0, X, I0, A, I0)') "send from: ", comm%local_rank, comm%local_section,  " to  : ", comm%neighbor_rank, comm%neighbor_section, " send tag: ", send_tag

                        assert_veq(comm%send_requests, MPI_REQUEST_NULL)

                        call mpi_isend(get_c_pointer(comm%p_local_edges), sizeof(comm%p_local_edges),        MPI_BYTE, comm%neighbor_rank, send_tag, MPI_COMM_WORLD, comm%send_requests(1), i_error); assert_eq(i_error, 0)
                        call mpi_isend(get_c_pointer(comm%p_local_nodes), sizeof(comm%p_local_nodes),        MPI_BYTE, comm%neighbor_rank, send_tag, MPI_COMM_WORLD, comm%send_requests(2), i_error); assert_eq(i_error, 0)

                        assert_vne(comm%send_requests, MPI_REQUEST_NULL)
                    end if
                end do
            end do
#       endif
    end subroutine

    subroutine recv_mpi_boundary(section)
        type(t_grid_section), intent(inout)				:: section

        integer (kind = GRID_SI)						:: i_comm
        integer                                         :: i_error, send_tag, recv_tag
        integer (kind = 1)							    :: i_color
        type(t_comm_interface), pointer			        :: comm

        _log_write(4, '(4X, A, I0)') "recv mpi boundary: section ", section%index

#        if defined(_MPI)
             do i_color = RED, GREEN
                _log_write(4, '(5X, A, A)') trim(color_to_char(i_color)), ":"

                do i_comm = 1, size(section%comms(i_color)%elements)
                    comm => section%comms(i_color)%elements(i_comm)

                    assert(associated(comm%p_local_edges))
                    assert(associated(comm%p_local_nodes))

                    if (comm%neighbor_rank .ge. 0 .and. comm%neighbor_rank .ne. rank_MPI) then
                        _log_write(4, '(6X, A)') trim(comm%to_string())
                        assert(associated(comm%p_neighbor_edges))
                        assert(associated(comm%p_neighbor_nodes))

                        send_tag = ishft(comm%local_section, 16) + comm%neighbor_section
                        recv_tag = ishft(comm%neighbor_section, 16) + comm%local_section

                        _log_write(5, '(7X, A, I0, X, I0, A, I0, X, I0, A, I0)') "recv to  : ", comm%local_rank, comm%local_section, " from: ", comm%neighbor_rank, comm%neighbor_section, " recv tag: ", recv_tag

                        assert_veq(comm%recv_requests, MPI_REQUEST_NULL)

                        call mpi_irecv(get_c_pointer(comm%p_neighbor_edges), sizeof(comm%p_neighbor_edges),  MPI_BYTE, comm%neighbor_rank, recv_tag, MPI_COMM_WORLD, comm%recv_requests(1), i_error); assert_eq(i_error, 0)
                        call mpi_irecv(get_c_pointer(comm%p_neighbor_nodes), sizeof(comm%p_neighbor_nodes),  MPI_BYTE, comm%neighbor_rank, recv_tag, MPI_COMM_WORLD, comm%recv_requests(2), i_error); assert_eq(i_error, 0)

                        assert_vne(comm%recv_requests, MPI_REQUEST_NULL)
                    end if
                end do
            end do
#       endif
    end subroutine

    subroutine sync_boundary(grid, edge_merge_op, node_merge_op, edge_write_op, node_write_op)
        type(t_grid), intent(inout)						:: grid
        procedure(op_edge_merge)                        :: edge_merge_op, edge_write_op
        procedure(op_node_merge)                        :: node_merge_op, node_write_op

        integer (kind = GRID_SI)						:: i_section, i_first_local_section, i_last_local_section, i_comm
        integer                                         :: i_error
        integer (kind = 1)							    :: i_color
        type(t_grid_section), pointer					:: section
        type(t_comm_interface), pointer			        :: comm
        integer (kind = GRID_SI)       					:: i_first_node, i_last_node, i

        _log_write(4, '(3X, A)') "sync boundary sections:"

        !$omp barrier

        call grid%get_local_sections(i_first_local_section, i_last_local_section)

        !gather neighbor boundary and merge with local boundary

        do i_section = i_first_local_section, i_last_local_section
            section => grid%sections%elements_alloc(i_section)
            assert_eq(i_section, section%index)

            _log_write(4, '(4X, A, I0)') "gather neighbor data: section ", section%index

             do i_color = RED, GREEN
                _log_write(4, '(5X, A, A)') trim(color_to_char(i_color)), ":"

#               if defined(_MPI)
                    !make sure that the section has finished all its mpi communication before proceeding
                    !otherwise a race condition might occur when merging boundary data

                    _log_write(4, '(6X, "wait for MPI neighbors:")')
                    do i_comm = 1, size(section%comms(i_color)%elements)
                        comm => section%comms(i_color)%elements(i_comm)

                        assert(associated(comm%p_local_edges))
                        assert(associated(comm%p_local_nodes))

                        if (comm%neighbor_rank .ne. rank_MPI .and. comm%neighbor_rank .ge. 0) then
                            _log_write(4, '(7X, (A))') trim(comm%to_string())

                            assert(associated(comm%p_neighbor_edges))
                            assert(associated(comm%p_neighbor_nodes))

                            _log_write(5, '(8X, A, I0, X, I0, A, I0, X, I0)') "wait from: ", comm%local_rank, comm%local_section, " to  : ", comm%neighbor_rank, comm%neighbor_section
                            _log_write(5, '(8X, A, I0, X, I0, A, I0, X, I0)') "wait to  : ", comm%local_rank, comm%local_section, " from: ", comm%neighbor_rank, comm%neighbor_section

                            assert_vne(comm%send_requests, MPI_REQUEST_NULL)
                            assert_vne(comm%recv_requests, MPI_REQUEST_NULL)

                            call mpi_wait(comm%send_requests(1), MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)
                            call mpi_wait(comm%send_requests(2), MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)
                            call mpi_wait(comm%recv_requests(1), MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)
                            call mpi_wait(comm%recv_requests(2), MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)

                            comm%send_requests = MPI_REQUEST_NULL
                            comm%recv_requests = MPI_REQUEST_NULL
                        end if
                    end do
#               endif

                !gather data in section with lowest index

                _log_write(4, '(6X, "merge edges and nodes:")')
                do i_comm = 1, size(section%comms(i_color)%elements)
                    comm => section%comms(i_color)%elements(i_comm)

                    assert(associated(comm%p_local_edges))
                    assert(associated(comm%p_local_nodes))

                    if (comm%neighbor_rank .ge. 0) then
                        assert(associated(comm%p_neighbor_edges))
                        assert(associated(comm%p_neighbor_nodes))

                        if (comm%neighbor_rank .eq. rank_MPI) then
                            !The way we defined ownership implies that the current section cannot own
                            !any edges or nodes, if the neighbor section is of lower index.
                            !In this case we can skip communication with this particular section.
                            if (comm%neighbor_section < section%index) cycle
                        end if

                        _log_write(4, '(7X, (A))') trim(comm%to_string())

                        !merge on local edges
                        !only the owner may execute merge operations (a race condition might occur otherwise)

                        assert_veq(decode_distance(comm%p_local_edges%min_distance), decode_distance(comm%p_neighbor_edges(comm%i_edges : 1 : -1)%min_distance))

                        do i = 1, comm%i_edges
                            section%l_conform = section%l_conform .and. edge_merge_op(comm%p_local_edges(i), comm%p_neighbor_edges(comm%i_edges + 1 - i))
                        end do

                        assert_veq(decode_distance(comm%p_local_nodes%distance), decode_distance(comm%p_neighbor_nodes(comm%i_nodes : 1 : -1)%distance))
                        assert_veq(comm%p_local_nodes%position(1), comm%p_neighbor_nodes(comm%i_nodes : 1 : -1)%position(1))
                        assert_veq(comm%p_local_nodes%position(2), comm%p_neighbor_nodes(comm%i_nodes : 1 : -1)%position(2))

                        !merge on local nodes
                        !only the owner may execute merge operations (a race condition might occur otherwise)

                        i_first_node = 1
                        if (.not. comm%p_local_nodes(1)%owned_locally) then
                            i_first_node = 2
                        end if

                        i_last_node = comm%i_nodes
                        if (.not. comm%p_local_nodes(comm%i_nodes)%owned_locally) then
                            i_last_node = comm%i_nodes - 1
                        end if

                        do i = i_first_node, i_last_node
                            section%l_conform = section%l_conform .and. node_merge_op(&
                                comm%p_local_nodes(i), &
                                comm%p_neighbor_nodes(comm%i_nodes + 1 - i) &
                            )
                        end do
                    end if
                end do
            end do
        end do

        !$omp barrier

        !write back merged neighbor boundary to local boundary

        !we may do this only after all sections have finished merging,
        !because only then do we know for sure, that all mpi_wait calls are finished.

        do i_section = i_first_local_section, i_last_local_section
            section => grid%sections%elements_alloc(i_section)
            assert_eq(i_section, section%index)

            _log_write(4, '(4X, A, I0)') "write merged data to neighbors: section ", section%index

            do i_color = RED, GREEN
                _log_write(4, '(5X, A, A)') trim(color_to_char(i_color)), ":"

                do i_comm = 1, size(section%comms(i_color)%elements)
                    comm => section%comms(i_color)%elements(i_comm)

                    if (comm%neighbor_rank .eq. rank_MPI .and. comm%neighbor_section < section%index) then
                        !write to comm edges and nodes
                        !only the owner may execute write operations

                        do i = 1, comm%i_edges
                            section%l_conform = section%l_conform .and. edge_write_op(comm%p_local_edges(i), comm%p_neighbor_edges(comm%i_edges + 1 - i))
                        end do

                        i_first_node = 1
                        if (.not. comm%p_neighbor_nodes(comm%i_nodes)%owned_locally) then
                            i_first_node = 2
                        end if

                        i_last_node = comm%i_nodes
                        if (.not. comm%p_neighbor_nodes(1)%owned_locally) then
                            i_last_node = comm%i_nodes - 1
                        end if

                        do i = i_first_node, i_last_node
                            section%l_conform = section%l_conform .and. node_write_op(&
                                comm%p_local_nodes(i), &
                                comm%p_neighbor_nodes(comm%i_nodes + 1 - i) &
                            )
                        end do
                    end if
                end do
            end do
        end do

        !$omp barrier
    end subroutine

    function distribute_load(grid) result(imbalance)
        type(t_grid), intent(inout)						:: grid
        integer                                         :: imbalance

        integer (kind = GRID_DI)						:: tmp_distances(RED: GREEN)
        integer (kind = GRID_SI)						:: i_section, i_first_local_section, i_last_local_section, i_comm
        integer						                    :: previous_requests(2), next_requests(2), i_error, send_tag, recv_tag
        double precision						        :: r_total_load
        integer						                    :: i_sections, i_previous_sections
        integer						                    :: new_rank, new_section
        integer, save                                   :: i_previous_sections_in, i_next_sections_in, i_previous_sections_out, i_next_sections_out
        integer (kind = 1)						        :: i_color
        type(t_grid_section)					        :: empty_section
        type(t_grid_section), pointer					:: section, section_nb
		type(t_comm_interface), pointer                 :: comm

        _log_write(3, '(3X, A)') "distribute load"
		imbalance = 0

#		if defined(_MPI)
		    previous_requests = MPI_REQUEST_NULL
		    next_requests = MPI_REQUEST_NULL

            call grid%get_local_sections(i_first_local_section, i_last_local_section)

            !$omp single
            i_previous_sections_out = 0
            i_next_sections_out = 0
            i_previous_sections_in = 0
            i_next_sections_in = 0

            call prefix_sum(grid%sections%elements_alloc%partial_load, grid%sections%elements_alloc%load)
            call reduce(grid%load, grid%sections%elements_alloc%load, MPI_SUM, .false.)

		    call mpi_scan(grid%load, grid%partial_load, 1, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, i_error); assert_eq(i_error, 0)
		    call mpi_allreduce(grid%load, r_total_load, 1, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, i_error); assert_eq(i_error, 0)
            !$omp end single copyprivate(r_total_load)

            i_sections = size(grid%sections%elements_alloc)

            !compute the number of sections, that are sent to left and right process neighbor

            do i_section = i_first_local_section, i_last_local_section
                section => grid%sections%elements_alloc(i_section)
                assert_eq(section%index, i_section)

                !if the last cell index of this section is less than the first cell index for this rank (after load balancing),
                !then move this section to the previous rank

                !if the first cell index of this section is greater than the last cell index for this rank (after load balancing),
                !then move this section to the next rank

                if ((grid%partial_load - grid%load + section%partial_load - 0.5_GRID_SR * section%load) * size_MPI < r_total_load * rank_MPI) then
                    !$omp atomic
                    i_previous_sections_out = i_previous_sections_out + 1
                end if

                if ((grid%partial_load - grid%load + section%partial_load - 0.5_GRID_SR * section%load) * size_MPI > r_total_load * (rank_MPI + 1)) then
                    !$omp atomic
                    i_next_sections_out = i_next_sections_out + 1
                end if
            end do

            assert_le(i_previous_sections_out + i_next_sections_out, i_sections)

            !$omp single
            !compute current imblance
            imbalance = i_previous_sections_out + i_next_sections_out
		    call mpi_allreduce(MPI_IN_PLACE, imbalance, 1, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, i_error); assert_eq(i_error, 0)
            !$omp end single copyprivate(imbalance)

            !exit early if the imbalance is small enough
            if (imbalance .le. 0) then
                _log_write(3, '(4X, A)') "migrating sections: none, grid is sufficiently balanced."
               return
            end if

            !$omp single
 		    !Communicate the number of grid cells and sections with left and right process neighbors
            assert_veq(previous_requests, MPI_REQUEST_NULL)
		    assert_veq(next_requests, MPI_REQUEST_NULL)

		    if (rank_MPI > 0) then
                call mpi_isend(i_previous_sections_out,   1, MPI_INTEGER, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(1), i_error); assert_eq(i_error, 0)
                call mpi_irecv(i_previous_sections_in,   1, MPI_INTEGER, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(2), i_error); assert_eq(i_error, 0)
		    else
                assert_eq(i_previous_sections_in, 0)
                assert_eq(i_previous_sections_out, 0)
		    end if

		    if (rank_MPI < size_MPI - 1) then
                call mpi_isend(i_next_sections_out,       1, MPI_INTEGER, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(1), i_error); assert_eq(i_error, 0)
                call mpi_irecv(i_next_sections_in,       1, MPI_INTEGER, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(2), i_error); assert_eq(i_error, 0)
		    else
                assert_eq(i_next_sections_in, 0)
                assert_eq(i_next_sections_out, 0)
            end if

            call mpi_waitall(2, previous_requests, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)
        	call mpi_waitall(2, next_requests, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)

            !either send or receive sections in one direction, but not both
        	assert_eq(min(i_previous_sections_in, i_previous_sections_out), 0)
            assert_eq(min(i_next_sections_in, i_next_sections_out), 0)

            previous_requests(1:2) = MPI_REQUEST_NULL
            next_requests(1:2) = MPI_REQUEST_NULL

           _log_write(3, '(4X, A, A, I0, A, I0)') "migrating sections: ", "previous rank: ", i_previous_sections_out - i_previous_sections_in, " next rank: ", i_next_sections_out - i_next_sections_in

            assert_veq(previous_requests, MPI_REQUEST_NULL)
		    assert_veq(next_requests, MPI_REQUEST_NULL)

            !receive the number of sections the previous neighbor has after load balancing
            !in order to set the section indices correctly

            if (i_next_sections_in > 0) then
                i_sections = i_sections + i_previous_sections_in - i_previous_sections_out + i_next_sections_in - i_next_sections_out
		    	call mpi_isend(i_sections,	            1, MPI_INTEGER, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(1), i_error); assert_eq(i_error, 0)
            end if

		    if (i_previous_sections_out > 0) then
		    	call mpi_irecv(i_previous_sections,	    1, MPI_INTEGER, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(1), i_error); assert_eq(i_error, 0)
            end if

        	call mpi_wait(previous_requests(1), MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)
        	call mpi_wait(next_requests(1), MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)

            previous_requests(1) = MPI_REQUEST_NULL
            next_requests(1) = MPI_REQUEST_NULL
            !$omp end single copyprivate(i_previous_sections_in, i_next_sections_in, i_previous_sections)

            !Rank and section index of first and last section may have been changed,
            !so send the new information to all neighbors of the sections.
            !Since the other processes cannot possibly know if something changed between two neighbors, we have to send this information to all neighbors

            _log_write(4, '(4X, A)') "grid distances (before):"
            _log_write(4, '(5X, A, 2(F0.4, X))') "start:", decode_distance(grid%start_distance)
            _log_write(4, '(5X, A, 2(F0.4, X))') "min  :", decode_distance(grid%min_distance)
            _log_write(4, '(5X, A, 2(F0.4, X))') "end  :", decode_distance(grid%end_distance)

            do i_section = i_first_local_section, i_last_local_section
                section => grid%sections%elements_alloc(i_section)
                assert_eq(section%index, i_section)
                _log_write(4, '(4X, A, I0)') "section send/recv comm changes: ", i_section

                if (i_section .le. i_previous_sections_out) then
                    new_rank = rank_MPI - 1
                    new_section = i_previous_sections - i_previous_sections_out + i_section
                else if (i_section .ge. size(grid%sections%elements_alloc) + 1 - i_next_sections_out) then
                    new_rank = rank_MPI + 1
                    new_section = i_section - size(grid%sections%elements_alloc) + i_next_sections_out
                else
                    new_rank = rank_MPI
                    new_section = i_section + i_previous_sections_in - i_previous_sections_out
                end if

                section%index = new_section

                do i_color = RED, GREEN
                    _log_write(4, '(5X, A, A)') trim(color_to_char(i_color)), ":"

                    do i_comm = 1, size(section%comms(i_color)%elements)
                        comm => section%comms(i_color)%elements(i_comm)
                        _log_write(4, '(6X, A)') trim(comm%to_string())

                        send_tag = ishft(comm%local_section, 16) + comm%neighbor_section
                        recv_tag = ishft(comm%neighbor_section, 16) + comm%local_section
                        comm%local_rank = new_rank
                        comm%local_section = new_section

                        if (comm%neighbor_rank .ge. 0) then
                            call comm%destroy_buffer()

                            _log_write(4, '(7X, A, I0, X, I0, A, I0, X, I0, A, I0)') "send from: ", comm%local_rank, comm%local_section,  " to  : ", comm%neighbor_rank, comm%neighbor_section, " send tag: ", send_tag
                            _log_write(4, '(7X, A, I0, X, I0, A, I0, X, I0, A, I0)') "recv to  : ", comm%local_rank, comm%local_section, " from: ", comm%neighbor_rank, comm%neighbor_section, " recv tag: ", recv_tag

                            assert_veq(comm%send_requests, MPI_REQUEST_NULL)
                            assert_veq(comm%recv_requests, MPI_REQUEST_NULL)

                            call mpi_isend(comm%local_section,           1, MPI_INTEGER, comm%neighbor_rank, send_tag, MPI_COMM_WORLD, comm%send_requests(1), i_error); assert_eq(i_error, 0)
                            call mpi_isend(comm%local_rank,              1, MPI_INTEGER, comm%neighbor_rank, send_tag, MPI_COMM_WORLD, comm%send_requests(2), i_error); assert_eq(i_error, 0)
                            call mpi_irecv(comm%neighbor_section,        1, MPI_INTEGER, comm%neighbor_rank, recv_tag, MPI_COMM_WORLD, comm%recv_requests(1), i_error); assert_eq(i_error, 0)
                            call mpi_irecv(comm%neighbor_rank,           1, MPI_INTEGER, comm%neighbor_rank, recv_tag, MPI_COMM_WORLD, comm%recv_requests(2), i_error); assert_eq(i_error, 0)

                            assert_vne(comm%send_requests, MPI_REQUEST_NULL)
                            assert_vne(comm%recv_requests, MPI_REQUEST_NULL)
                        end if
                    end do
                end do
            end do

            !$omp barrier

            !wait until all sections sent and received their communication changes
            do i_section = i_first_local_section, i_last_local_section
                section => grid%sections%elements_alloc(i_section)

                _log_write(4, '(4X, A, I0)') "section wait for send/recv comm changes: ", i_section

                do i_color = RED, GREEN
                    _log_write(4, '(5X, A, A)') trim(color_to_char(i_color)), ":"
                    do i_comm = 1, size(section%comms(i_color)%elements)
                        comm => section%comms(i_color)%elements(i_comm)

                        _log_write(4, '(6X, A)') trim(comm%to_string())

                        if (comm%neighbor_rank .ge. 0) then
                            _log_write(4, '(7X, A, I0, X, I0, A, I0, X, I0)') "wait from: ", comm%local_rank, comm%local_section, " to  : ", comm%neighbor_rank, comm%neighbor_section
                            _log_write(4, '(7X, A, I0, X, I0, A, I0, X, I0)') "wait to  : ", comm%local_rank, comm%local_section, " from: ", comm%neighbor_rank, comm%neighbor_section

                            assert_vne(comm%send_requests, MPI_REQUEST_NULL)
                            assert_vne(comm%recv_requests, MPI_REQUEST_NULL)

                            call mpi_waitall(2, comm%send_requests, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)
                            call mpi_waitall(2, comm%recv_requests, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)

                            comm%send_requests = MPI_REQUEST_NULL
                            comm%recv_requests = MPI_REQUEST_NULL
                        end if
                    end do
                end do
            end do

            !$omp barrier

            !exit early if nothing changes on this rank
            if (i_previous_sections_in + i_previous_sections_out + i_next_sections_in + i_next_sections_out == 0) then
                return
            end if

            !$omp single
            if (size(grid%sections%elements) > 0) then
                assert_veq(decode_distance(grid%start_distance), decode_distance(grid%sections%elements(1)%start_distance))
                assert_veq(decode_distance(grid%end_distance), decode_distance(grid%sections%elements(size(grid%sections%elements))%end_distance))
            end if

            _log_write(4, '(4X, A, I0)') "migrate sections:"

            if (i_previous_sections_in + i_next_sections_in > 0) then
                call grid%sections%resize(size(grid%sections%elements_alloc) + i_previous_sections_in + i_next_sections_in, 1, 1 + i_previous_sections_in, size(grid%sections%elements_alloc))
            end if

            call send_recv_section_infos(grid, i_previous_sections_in, i_previous_sections_out, i_next_sections_in, i_next_sections_out)
            call send_recv_section_data(grid, i_previous_sections_in, i_previous_sections_out, i_next_sections_in, i_next_sections_out)

            if (i_previous_sections_out + i_next_sections_out > 0) then
                do i_section = 1, i_previous_sections_out
                    call grid%sections%elements_alloc(i_section)%destroy()
                end do

                do i_section = 1, i_next_sections_out
                    call grid%sections%elements_alloc(size(grid%sections%elements_alloc) + 1 - i_section)%destroy()
                end do

                call grid%sections%resize(size(grid%sections%elements_alloc) - i_previous_sections_out - i_next_sections_out, 1 + i_previous_sections_out, 1, size(grid%sections%elements_alloc) - i_previous_sections_out - i_next_sections_out)
            end if

            do i_section = 1, i_previous_sections_in
                section => grid%sections%elements_alloc(i_section)

                if (section%cells%elements(1)%get_previous_edge_type() .ne. OLD_BND) then
                    _log_write(4, '(A, I0)') "Reversing section ", i_section
                    call section%reverse()

                    !do not swap distances
                    tmp_distances = section%start_distance
                    section%start_distance = section%end_distance
                    section%end_distance = tmp_distances

                    if (grid%sections%is_forward()) then
                        call grid%sections%reverse()
                    end if
                end if

                grid%max_dest_stack = grid%max_dest_stack + section%max_dest_stack - section%min_dest_stack + 1

                assert_eq(section%cells%elements(1)%get_previous_edge_type(), OLD_BND)
                assert(section%cells%is_forward() .eqv. section%boundary_edges(RED)%is_forward())

                !fix the order of old/new comms
                do i_color = RED, GREEN
                    section%comms_type(OLD, i_color)%elements => section%comms(i_color)%elements(1 : size(section%comms_type(OLD, i_color)%elements))
                    section%comms_type(NEW, i_color)%elements => section%comms(i_color)%elements(size(section%comms_type(OLD, i_color)%elements) + 1 : size(section%comms(i_color)%elements))
                end do
            end do

            do i_section = 1, i_next_sections_in
                section => grid%sections%elements_alloc(size(grid%sections%elements_alloc) - i_next_sections_in + i_section)

                if (section%cells%elements(1)%get_previous_edge_type() .ne. OLD_BND) then
                    _log_write(4, '(A, I0)') "Reversing section ", size(grid%sections%elements_alloc) + 1 - i_section
                    call section%reverse()

                    !do not swap distances
                    tmp_distances = section%start_distance
                    section%start_distance = section%end_distance
                    section%end_distance = tmp_distances

                    if (grid%sections%is_forward()) then
                        call grid%sections%reverse()
                    end if
                end if

                grid%max_dest_stack = grid%max_dest_stack + section%max_dest_stack - section%min_dest_stack + 1

                assert_eq(section%cells%elements(1)%get_previous_edge_type(), OLD_BND)
                assert(section%cells%is_forward() .eqv. section%boundary_edges(RED)%is_forward())

                !fix the order of old/new comms
                do i_color = RED, GREEN
                    section%comms_type(OLD, i_color)%elements => section%comms(i_color)%elements(1 : size(section%comms_type(OLD, i_color)%elements))
                    section%comms_type(NEW, i_color)%elements => section%comms(i_color)%elements(size(section%comms_type(OLD, i_color)%elements) + 1 : size(section%comms(i_color)%elements))
                end do
            end do

            !update distances again and check for correctness

            if (size(grid%sections%elements) > 0) then
                grid%start_distance = grid%sections%elements(1)%start_distance
                grid%end_distance = grid%sections%elements(size(grid%sections%elements))%end_distance
            else
                grid%start_distance = 0
                grid%end_distance = 0
            end if

            do i_color = RED, GREEN
                call reduce(grid%min_distance(i_color), grid%sections%elements%min_distance(i_color), MPI_MIN, .false.)
            end do

            call reduce(grid%dest_cells, grid%sections%elements%dest_cells, MPI_SUM, .false.)

            _log_write(4, '(4X, A)') "grid distances (after):"
            _log_write(4, '(5X, A, 2(F0.4, X))') "start:", decode_distance(grid%start_distance)
            _log_write(4, '(5X, A, 2(F0.4, X))') "min  :", decode_distance(grid%min_distance)
            _log_write(4, '(5X, A, 2(F0.4, X))') "end  :", decode_distance(grid%end_distance)
		    !$omp end single

            !resize stacks to make sure their size is big enough for the new sections
            call grid%threads%elements(1 + omp_get_thread_num())%destroy()
            call grid%threads%elements(1 + omp_get_thread_num())%create(grid%max_dest_stack - grid%min_dest_stack + 1)

            call grid%get_local_sections(i_first_local_section, i_last_local_section)

            do i_section = i_first_local_section, i_last_local_section
                section => grid%sections%elements_alloc(i_section)
                assert_eq(section%index, i_section)

                _log_write(4, '(4X, A, I0)') "section set local pointers: ", i_section

                do i_color = RED, GREEN
                    call set_comm_local_pointers(section, i_color)
                end do
            end do

            !$omp barrier

            do i_section = i_first_local_section, i_last_local_section
                section => grid%sections%elements_alloc(i_section)
                assert_eq(section%index, i_section)

                _log_write(4, '(4X, A, I0)') "section set neighbor pointers: ", i_section

                do i_color = RED, GREEN
                    call set_comm_neighbor_data(grid, section, i_color)
                end do
            end do

            !$omp barrier
#		endif
    end function

#	if defined(_MPI)
		subroutine send_recv_section_infos(grid, i_previous_sections_in, i_previous_sections_out, i_next_sections_in, i_next_sections_out)
		    type(t_grid), intent(inout)						:: grid
		    integer, intent(in)                             :: i_previous_sections_in, i_next_sections_in, i_previous_sections_out, i_next_sections_out

		    integer						                    :: i_section, i_error
		    integer (kind = 1)						        :: i_color
		    type(t_grid_section), pointer					:: section
		    integer						                    :: previous_request, next_request
			type(t_section_info), allocatable               :: previous_section_infos(:), next_section_infos(:)

			allocate(previous_section_infos(max(i_previous_sections_in, i_previous_sections_out)), stat=i_error); assert_eq(i_error, 0)
			allocate(next_section_infos(max(i_next_sections_in, i_next_sections_out)), stat=i_error); assert_eq(i_error, 0)

		    !exchange section infos
		    previous_request = MPI_REQUEST_NULL
		    next_request = MPI_REQUEST_NULL

		    do i_section = 1, i_previous_sections_out
		        previous_section_infos(i_section) = grid%sections%elements_alloc(i_section)%get_capacity()
		    end do

		    do i_section = 1, i_next_sections_out
		        next_section_infos(i_section) = grid%sections%elements_alloc(size(grid%sections%elements_alloc) - i_next_sections_out + i_section)%get_capacity()
		    end do

		    if (i_previous_sections_out > 0) then
		        call mpi_isend(previous_section_infos(1), i_previous_sections_out * sizeof(previous_section_infos(1)), MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_request, i_error); assert_eq(i_error, 0)
		    else if (i_previous_sections_in > 0) then
		        call mpi_irecv(previous_section_infos(1), i_previous_sections_in * sizeof(previous_section_infos(1)), MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_request, i_error); assert_eq(i_error, 0)
		    end if

		    if (i_next_sections_out > 0) then
		        call mpi_isend(next_section_infos(1), i_next_sections_out * sizeof(next_section_infos(1)), MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_request, i_error); assert_eq(i_error, 0)
		    else if (i_next_sections_in > 0) then
		        call mpi_irecv(next_section_infos(1), i_next_sections_in * sizeof(next_section_infos(1)), MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_request, i_error); assert_eq(i_error, 0)
		    end if

		    call mpi_wait(previous_request, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)
		    call mpi_wait(next_request, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)

		    do i_section = 1, i_previous_sections_in
		        section => grid%sections%elements_alloc(i_section)

		        call section%create(previous_section_infos(i_section))
		    end do

		    do i_section = 1, i_next_sections_in
		        section => grid%sections%elements_alloc(size(grid%sections%elements_alloc) - i_next_sections_in + i_section)

		        call section%create(next_section_infos(i_section))
		    end do

			deallocate(previous_section_infos, stat=i_error); assert_eq(i_error, 0)
			deallocate(next_section_infos, stat=i_error); assert_eq(i_error, 0)
		end subroutine

		subroutine send_recv_section_data(grid, i_previous_sections_in, i_previous_sections_out, i_next_sections_in, i_next_sections_out)
		    type(t_grid), intent(inout)						:: grid
		    integer, intent(in)                             :: i_previous_sections_in, i_next_sections_in, i_previous_sections_out, i_next_sections_out

		    integer						                    :: i_section, i_error
		    integer (kind = 1)						        :: i_color
		    type(t_grid_section), pointer					:: section
			type(t_section_info), allocatable               :: previous_section_infos(:), next_section_infos(:)
		    integer, allocatable 						    :: previous_requests(:, :), next_requests(:, :)

			allocate(previous_requests(11, max(i_previous_sections_in, i_previous_sections_out)), stat=i_error); assert_eq(i_error, 0)
			allocate(next_requests(11, max(i_next_sections_in, i_next_sections_out)), stat=i_error); assert_eq(i_error, 0)

		    !exchange sections
		    previous_requests = MPI_REQUEST_NULL
		    next_requests = MPI_REQUEST_NULL

		    do i_section = 1, i_previous_sections_out
		        section => grid%sections%elements_alloc(i_section)

		        call mpi_isend(section%t_global_data, sizeof(section%t_global_data), MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(1, i_section), i_error); assert_eq(i_error, 0)

		        call mpi_isend(section%cells%get_c_pointer(),             sizeof(section%cells%elements),                MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(2, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_isend(section%crossed_edges_in%get_c_pointer(),  sizeof(section%crossed_edges_in%elements),     MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(3, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_isend(section%color_edges_in%get_c_pointer(),    sizeof(section%color_edges_in%elements),       MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(4, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_isend(section%nodes_in%get_c_pointer(),          sizeof(section%nodes_in%elements),             MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(5, i_section), i_error); assert_eq(i_error, 0)

		        do i_color = RED, GREEN
		            call mpi_isend(section%boundary_edges(i_color)%get_c_pointer(), sizeof(section%boundary_edges(i_color)%elements),  MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(7 + i_color, i_section), i_error); assert_eq(i_error, 0)
		            call mpi_isend(section%boundary_nodes(i_color)%get_c_pointer(), sizeof(section%boundary_nodes(i_color)%elements),  MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(9 + i_color, i_section), i_error); assert_eq(i_error, 0)
		            call mpi_isend(section%comms(i_color)%get_c_pointer(), sizeof(section%comms(i_color)%elements),                    MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(11 + i_color, i_section), i_error); assert_eq(i_error, 0)
		        end do
		    end do

		    do i_section = 1, i_next_sections_out
		        section => grid%sections%elements_alloc(size(grid%sections%elements_alloc) - i_next_sections_out + i_section)

		        call mpi_isend(section%t_global_data, sizeof(section%t_global_data), MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(1, i_section), i_error); assert_eq(i_error, 0)

		        call mpi_isend(section%cells%get_c_pointer(),             sizeof(section%cells%elements),              MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(2, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_isend(section%crossed_edges_in%get_c_pointer(),  sizeof(section%crossed_edges_in%elements),   MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(3, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_isend(section%color_edges_in%get_c_pointer(),    sizeof(section%color_edges_in%elements),     MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(4, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_isend(section%nodes_in%get_c_pointer(),          sizeof(section%nodes_in%elements),           MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(5, i_section), i_error); assert_eq(i_error, 0)

		        do i_color = RED, GREEN
		            call mpi_isend(section%boundary_edges(i_color)%get_c_pointer(),   sizeof(section%boundary_edges(i_color)%elements),  MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(7 + i_color, i_section), i_error); assert_eq(i_error, 0)
		            call mpi_isend(section%boundary_nodes(i_color)%get_c_pointer(),   sizeof(section%boundary_nodes(i_color)%elements),  MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(9 + i_color, i_section), i_error); assert_eq(i_error, 0)
		            call mpi_isend(section%comms(i_color)%get_c_pointer(),            sizeof(section%comms(i_color)%elements),           MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(11 + i_color, i_section), i_error); assert_eq(i_error, 0)
		        end do
		    end do

		    do i_section = 1, i_previous_sections_in
		        section => grid%sections%elements_alloc(i_section)

		        call mpi_irecv(section%t_global_data, sizeof(section%t_global_data), MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(1, i_section), i_error); assert_eq(i_error, 0)

		        call mpi_irecv(section%cells%get_c_pointer(),                  sizeof(section%cells%elements),            MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(2, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_irecv(section%crossed_edges_in%get_c_pointer(),       sizeof(section%crossed_edges_in%elements), MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(3, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_irecv(section%color_edges_in%get_c_pointer(),         sizeof(section%color_edges_in%elements),   MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(4, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_irecv(section%nodes_in%get_c_pointer(),               sizeof(section%nodes_in%elements),         MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(5, i_section), i_error); assert_eq(i_error, 0)

		        do i_color = RED, GREEN
		            call mpi_irecv(section%boundary_edges(i_color)%get_c_pointer(),  sizeof(section%boundary_edges(i_color)%elements), MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(7 + i_color, i_section), i_error); assert_eq(i_error, 0)
		            call mpi_irecv(section%boundary_nodes(i_color)%get_c_pointer(),  sizeof(section%boundary_nodes(i_color)%elements), MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(9 + i_color, i_section), i_error); assert_eq(i_error, 0)
		            call mpi_irecv(section%comms(i_color)%get_c_pointer(),           sizeof(section%comms(i_color)%elements),          MPI_BYTE, rank_MPI - 1, 0, MPI_COMM_WORLD, previous_requests(11 + i_color, i_section), i_error); assert_eq(i_error, 0)
		        end do
		    end do

		    do i_section = 1, i_next_sections_in
		        section => grid%sections%elements_alloc(size(grid%sections%elements_alloc) - i_next_sections_in + i_section)

		        call mpi_irecv(section%t_global_data, sizeof(section%t_global_data), MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(1, i_section), i_error); assert_eq(i_error, 0)

		        call mpi_irecv(section%cells%get_c_pointer(),             sizeof(section%cells%elements),              MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(2, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_irecv(section%crossed_edges_in%get_c_pointer(),  sizeof(section%crossed_edges_in%elements),   MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(3, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_irecv(section%color_edges_in%get_c_pointer(),    sizeof(section%color_edges_in%elements),     MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(4, i_section), i_error); assert_eq(i_error, 0)
		        call mpi_irecv(section%nodes_in%get_c_pointer(),          sizeof(section%nodes_in%elements),           MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(5, i_section), i_error); assert_eq(i_error, 0)

		        do i_color = RED, GREEN
		            call mpi_irecv(section%boundary_edges(i_color)%get_c_pointer(),   sizeof(section%boundary_edges(i_color)%elements),  MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(7 + i_color, i_section), i_error); assert_eq(i_error, 0)
		            call mpi_irecv(section%boundary_nodes(i_color)%get_c_pointer(),   sizeof(section%boundary_nodes(i_color)%elements),  MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(9 + i_color, i_section), i_error); assert_eq(i_error, 0)
		            call mpi_irecv(section%comms(i_color)%get_c_pointer(),            sizeof(section%comms(i_color)%elements),           MPI_BYTE, rank_MPI + 1, 0, MPI_COMM_WORLD, next_requests(11 + i_color, i_section), i_error); assert_eq(i_error, 0)
		        end do
		    end do

		    !wait until the load has been distributed by all neighbor processes

		    call mpi_waitall(11 * max(i_previous_sections_in, i_previous_sections_out), previous_requests, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)
		    call mpi_waitall(11 * max(i_next_sections_in, i_next_sections_out), next_requests, MPI_STATUSES_IGNORE, i_error); assert_eq(i_error, 0)

			deallocate(previous_requests, stat=i_error); assert_eq(i_error, 0)
			deallocate(next_requests, stat=i_error); assert_eq(i_error, 0)
		end subroutine
#	endif

    subroutine find_section_boundary_elements(thread, section, last_cell_index, last_crossed_edge_data)
        type(t_grid_thread), intent(inout)	                        :: thread
        type(t_grid_section), intent(inout)	                        :: section
        integer (kind = GRID_DI), intent(in)		                :: last_cell_index
        type(t_edge_data), intent(in)	                            :: last_crossed_edge_data

        type(t_edge_data), pointer                                  :: p_edge, p_edges(:)
        type(t_node_data), pointer                                  :: p_nodes(:)
        integer(kind = GRID_SI)							            :: i_color, i_pass, i_cell, i_edges, i_nodes, i

        _log_write(4, '(2X, A, I0)') "find section boundary elements: ", section%index

        !set the last cell of the current section to a new boundary cell
        assert_ge(last_cell_index, 1)
        assert_le(last_cell_index, size(section%cells%elements))
        call section%cells%elements(last_cell_index)%set_previous_edge_type(OLD_BND)

        !and move the last crossed edge to the red stack
        p_edge => thread%edges_stack(RED)%push()
        p_edge = last_crossed_edge_data

        !find additional process edges and nodes
        do i_color = RED, GREEN
            !all cell indices that remain on the index stack are of new boundary cells
            call section%cells%elements(thread%indices_stack(i_color)%elements(1 : thread%indices_stack(i_color)%i_current_element))%set_color_edge_type(OLD_BND)

            section%min_distance(i_color) = 0

            !all edges on the boundary stream are old boundary edges

            i_edges = section%boundary_edges(i_color)%i_current_element
            p_edges => section%boundary_edges(i_color)%elements(i_edges : 1 : -1)
            call section%boundary_type_edges(OLD, i_color)%attach(p_edges)
            call section%boundary_type_edges(OLD, i_color)%reverse()

            if (i_edges > 0) then
                p_edges(1)%min_distance = 0
                p_edges(2 : i_edges)%min_distance = encode_edge_size(p_edges(1 : i_edges - 1)%depth)
                call prefix_sum(p_edges%min_distance, p_edges%min_distance)

                section%start_distance(i_color) = p_edges(i_edges)%min_distance + encode_edge_size(p_edges(i_edges)%depth)
            else
                section%start_distance(i_color) = 0
            end if

            !all nodes on the boundary stream are old boundary nodes

            i_nodes = section%boundary_nodes(i_color)%i_current_element
            p_nodes => section%boundary_nodes(i_color)%elements(i_nodes : 1 : -1)
            call section%boundary_type_nodes(OLD, i_color)%attach(p_nodes)
            call section%boundary_type_nodes(OLD, i_color)%reverse()

            if (i_nodes > i_edges) then
                assert_eq(i_nodes, i_edges + 1)
                p_nodes(1 : i_edges)%distance = p_edges%min_distance
                p_nodes(i_nodes)%distance = section%start_distance(i_color)
            else
                p_nodes%distance = p_edges%min_distance
            end if

            !all remaining edges on the stack are new boundary edges

            i_edges = thread%edges_stack(i_color)%i_current_element
            p_edges => section%boundary_edges(i_color)%elements(section%boundary_edges(i_color)%i_current_element + 1 : section%boundary_edges(i_color)%i_current_element + i_edges)
            section%boundary_edges(i_color)%i_current_element = section%boundary_edges(i_color)%i_current_element + i_edges
            p_edges = thread%edges_stack(i_color)%elements(1 : i_edges)
            call section%boundary_type_edges(NEW, i_color)%attach(p_edges)

            if (i_edges > 0) then
                p_edges(1)%min_distance = 0
                p_edges(2 : i_edges)%min_distance = encode_edge_size(p_edges(1 : i_edges - 1)%depth)
                call prefix_sum(p_edges%min_distance, p_edges%min_distance)

                section%end_distance(i_color) = p_edges(i_edges)%min_distance + encode_edge_size(p_edges(i_edges)%depth)
            else
                section%end_distance(i_color) = 0
            end if

            !all remaining nodes on the stack are new boundary nodes

            i_nodes = thread%nodes_stack(i_color)%i_current_element
            p_nodes => section%boundary_nodes(i_color)%elements(section%boundary_nodes(i_color)%i_current_element : section%boundary_nodes(i_color)%i_current_element + i_nodes - 1)
            section%boundary_nodes(i_color)%i_current_element = section%boundary_nodes(i_color)%i_current_element + i_nodes - 1
            p_nodes = thread%nodes_stack(i_color)%elements(1 : i_nodes)
            call section%boundary_type_nodes(NEW, i_color)%attach(p_nodes)

            if (i_nodes > i_edges) then
                assert_eq(i_nodes, i_edges + 1)
                p_nodes(1 : i_edges)%distance = p_edges%min_distance
                p_nodes(i_nodes)%distance = section%end_distance(i_color)
            else
                p_nodes%distance = p_edges%min_distance
            end if

            thread%indices_stack(i_color)%i_current_element = 0
            thread%edges_stack(i_color)%i_current_element = 0
            thread%nodes_stack(i_color)%i_current_element = 0
        end do

        call section%cells%trim()
        call section%crossed_edges_out%trim()
        section%crossed_edges_in = section%crossed_edges_out

        call section%nodes_out%trim()
        section%nodes_in = section%nodes_out

        call section%color_edges_out%trim()
        section%color_edges_in = section%color_edges_out

        call section%boundary_nodes%trim()
        call section%boundary_edges%trim()

#	    if (_DEBUG_LEVEL > 3)
            do i_color = RED, GREEN
                _log_write(4, '(3X, A, A)') trim(color_to_char(i_color)), ":"
                do i_pass = OLD, NEW
                    _log_write(4, '(4X, A, A)') trim(edge_type_to_char(i_pass)), ":"

                    p_edges => section%boundary_type_edges(i_pass, i_color)%elements
                    _log_write(4, '(5X, A, I0)') "boundary edges: ", size(p_edges)
                    do i = 1, size(p_edges)
                        _log_write(4, '(6X, F0.4, X, F0.4)') decode_distance(p_edges(i)%min_distance), decode_distance(p_edges(i)%min_distance + encode_edge_size(p_edges(i)%depth))
                    end do

                    p_nodes => section%boundary_type_nodes(i_pass, i_color)%elements
                    _log_write(4, '(5X, A, I0)') "boundary nodes: ", size(p_nodes)
                    do i = 1, size(p_nodes)
                        _log_write(4, '(6X, F0.4)') decode_distance(p_nodes(i)%distance)
                    end do
                end do
            end do
#	    endif

#	    if (_DEBUG_LEVEL > 4)
            _log_write(5, '(2X, A)') "destination section final state :"
            call section%print()
#	    endif
    end subroutine
end module

