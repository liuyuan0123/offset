% N-agent linear event-triggered cooperative localization
% w/ reduced state vectors
%
% Ian Loefgren
% 1.9.2019
%
% 2D linear cooperative localization, different from n_agent_lin_coop_loc.m
% in that the state vectors of each agent are reduced from the whole
% network's states.

clear; %close all; clc;
% load('sensor_noise_data.mat');

rng(999)

%% Specify connections

% connections = {[3],[3],[1,2,4],[3,5,6],[4],[4]};

% connections = {[2],[1,3],[2,4],[3,5],[4,6],[5]};

% connections = {[5],[5],[6],[6],[1,2,7],[3,4,7],[5,6,8],[7,9,10],[8,11,12],...
%                 [8,13,14],[9],[9],[10],[10]};

% tree, 30 agents
connections = {[9],[9],[10],[10],[11],[11],[12],[12],...
                [1,2,13],[3,4,13],[5,6,14],[7,8,14],[9,10,15],[11,12,15],[13,14,16],...
                [15,17,18],[16,19,20],[16,21,22],[17,23,24],[17,25,26],[18,27,28],...
                [18,29,30],[19],[19],[20],[20],[21],[21],[22],[22]};

% multiple hub chain, 30 agents
% connections = {[6],[6],[6],[6],[6],[1,2,3,4,5,12],...
%                 [12],[12],[12],[12],[12],[6,7,8,9,10,11,18],...
%                 [18],[18],[18],[18],[18],[12,13,14,15,16,17,24],...
%                 [24],[24],[24],[24],[24],[18,19,20,21,22,23,30],...
%                 [30],[30],[30],[30],[30],[24,25,26,27,28,29]};

            
% connections = {[9],[9],[10],[10],[11],[11],[12],[12],...
%                 [1,2,13],[3,4,13],[5,6,14],[7,8,14],[9,10,15],[11,12,15],[13,14,16],...
%                 [15,17,18],[16,19,20],[16,21,22],[17,23,24],[17,25,26],[18,27,28],...
%                 [18,29,30],[19],[19],[20],[20],[21],[21],[22],[22]};

% connections = {[2,3,4,5],[1,3,6,7],[1,2,8,9],[1],[1],[2],[2],[3],[3]};

% connections = {[2],[1]};
            
% specify which platforms get gps-like measurements
abs_meas_vec = [13 14 17 18];
% number of agents
N = length(connections);
% connection topology: tree
num_connections = 3;

% create graph and find shortest paths to gps nodes
[shortest_paths,g] = create_graph(connections,abs_meas_vec);

% delta_vec = 0:0.5:5;
% tau_state_goal_vec = 5:0.5:15;
% tau_state_vec = 0:0.5:25;

delta_vec = [1.5];
tau_state_goal_vec = [5 10 15 20];
msg_drop_prob_vec = [0];

% cost = zeros(length(delta_vec),length(tau_state_goal_vec),5);
w1 = 0.5;
w2 = 0.5;

loop_cnt = 1;

max_time = 50;
dt = 0.1;
input_tvec = 0:dt:max_time;

cost = zeros(length(delta_vec)*length(tau_state_goal_vec)*length(msg_drop_prob_vec),9);
network_mse = zeros(N,length(input_tvec),length(msg_drop_prob_vec));
baseline_mse = zeros(N,length(input_tvec),length(msg_drop_prob_vec));

for idx1=1:length(delta_vec)
for idx2=1:length(tau_state_goal_vec) 
for idx3=1:length(msg_drop_prob_vec)

% event-triggering  and covariance intersection params
% delta = 3;
delta = delta_vec(idx1);
% tau_goal = 100;
% tau = 70;
% tau_state_goal = 12.5;
tau_state_goal = tau_state_goal_vec(idx2);
% tau_state = 8.75;
% tau_state = tau_state_vec(idx3);
tau_state = 0.75*tau_state_goal;

use_adaptive = true;

% comms modeling params
msg_drop_prob = msg_drop_prob_vec(idx3);

% simulation params
% max_time = 20;
% dt = 0.1;
% input_tvec = 0:dt:max_time;

%% True starting position and input

for i=1:N
    x_true = [i*10,0,i*10,0]' + mvnrnd([0,0,0,0],diag([5 0.1 5 0.1]))';
    x_true_vec((i-1)*4+1:(i-1)*4+4,1) = x_true;
    
    % generate input for platforms
    u((i-1)*2+1:(i-1)*2+2,:) = [2*cos(0.75*input_tvec);2*sin(0.75*input_tvec)];
%     u((i-1)*2+1:(i-1)*2+2,:) = [0.05*input_tvec;0.5*input_tvec];
end

%% Create centralized KF

Q_local_true = [0.0003 0.005 0 0;
            0.005 0.1 0 0;
            0 0 0.0003 0.005;
            0 0 0.005 0.1];
        
Q_local = [0.0017 0.025 0 0;
            0.025 0.5 0 0;
            0 0 0.0017 0.025;
            0 0 0.025 0.5];

% R_abs = 1*eye(2);
R_abs = diag([1 1]);
R_rel = 3*eye(2);

% generate dynamics matrices for baseline filter
[F_full,G_full] = ncv_dyn(dt,N);
% Q_full = 1*eye(4*N);
Q_full_cell = cell(1,N);
[Q_full_cell{:}] = deal(Q_local);
Q_full = blkdiag(Q_full_cell{:});
x0_full = x_true_vec;
P0_full = 100*eye(4*N);

% create baseline filter for comparison
baseline_filter = KF(F_full,G_full,0,0,Q_full,R_abs,R_rel,x_true_vec,P0_full,0);


%% Create agents objects

% for each platform, create dynamics models, and filters

agents = cell(N,1);
ci_trigger_mat = zeros(N,length(input_tvec));
for i=1:N
    
    agent_id = i;

    ids = sort([agent_id,connections{i}]);
    % add shortest path to gps node to estimate
    gps_sp_ids = setdiff(shortest_paths{i},ids);
    ids = sort([ids,gps_sp_ids]);
    connections_new = sort([gps_sp_ids,connections{i}]);
    meas_connections = connections{i};
    
    est_state_length = length(ids);
    
    % construct local estimates
    n = (est_state_length)*4;
    [F,G] = ncv_dyn(dt,est_state_length);
%     Q_localfilter = 1*eye(n);
    Q_localfilter_cell = cell(1,est_state_length);
    [Q_localfilter_cell{:}] = deal(Q_local);
    Q_localfilter = blkdiag(Q_localfilter_cell{:});
       
    x0 = [];
    for j=1:length(ids)
        x0 = [x0; x_true_vec((ids(j)-1)*4+1:(ids(j)-1)*4+4,1)];
    end
    
    P0 = 100*eye(4*est_state_length);
    
    local_filter = ETKF(F,G,0,0,Q_localfilter,R_abs,R_rel,x0,P0,delta,agent_id,connections_new);
    
    % construct common estimates, will always only have two agents
    [F_comm,G_comm] = ncv_dyn(dt,2);
%     Q_comm = 1*eye(8);
    Q_comm = blkdiag(Q_local,Q_local);
    common_estimates = {};
    
    % list of connections that have extended gps
    forward_connections = [];
    
    for j=1:length(meas_connections)
        
        % make sure common estimate state vector is ordered by agent id
        comm_ids = sort([agent_id,meas_connections(j)]);
        x0_comm = [];
        
        for k=1:length(comm_ids)
            x0_comm = [x0_comm; x_true_vec((comm_ids(k)-1)*4+1:(comm_ids(k)-1)*4+4,1)];
        end

        P0_comm = 100*eye(8);
        common_estimates{j} = ETKF(F_comm,G_comm,0,0,Q_comm,R_abs,R_rel,x0_comm,P0_comm,delta,agent_id,meas_connections(j));
        
        if ~isempty(shortest_paths{meas_connections(j)})
            forward_connections = [forward_connections, meas_connections(j)];
        end
    
    end
    agents{i} = Agent(agent_id,connections_new,meas_connections,gps_sp_ids,...
                forward_connections,local_filter,common_estimates,x_true_vec((i-1)*4+1:(i-1)*4+4,1),...
                msg_drop_prob,length(x0)*tau_state_goal,length(x0)*tau_state);
    
end

%% Main Simulation Loop

H_local = [1 0 0 0; 0 0 1 0];
H_rel = [1 0 0 0 -1 0 0 0; 0 0 1 0 0 0 -1 0];
[F_local,G_local] = ncv_dyn(dt);
% Q_local = 0.1*eye(4);


ci_time_vec = zeros(N,length(input_tvec));
all_msgs = {};
abs_meas_mat = zeros(N,length(input_tvec),2);
rel_meas_mat = zeros(N,length(input_tvec),2);

for i = 2:length(input_tvec)
%     tic
    clc;
    fprintf('Iteration %i of %i\n',loop_cnt,length(delta_vec)*length(tau_state_goal_vec));
    fprintf('Delta: %f \t State tau goal: %f\n',delta,tau_state_goal);
    fprintf('Time step %i of %i, %f seconds of %f total\n',i,length(input_tvec),i*dt,length(input_tvec)*dt);
    
    % create measurement inbox
    inbox = cell(N,1);
    forward_inbox = cell(N,1);
    
    baseline_filter.predict(u(:,i));
%     baseline_filter.predict(zeros(size(u(:,i))));
    
    % process local measurements and determine which to send to connections
    for j=randperm(length(agents))
        msgs = {};
        
%         if i == 107 && j == 16
%             disp('break')
%         end
        
        % propagate true state
        w = mvnrnd([0,0,0,0],Q_local_true)';
%         w = w_data{j}(:,i);
        agents{j}.true_state(:,end+1) = F_local*agents{j}.true_state(:,end) + G_local*u(2*(j-1)+1:2*(j-1)+2,i) + w;
        
        % simulate measurements: absolute measurements
        if ismember(agents{j}.agent_id,abs_meas_vec)
            v = mvnrnd([0,0],R_abs)';
%             v = v_data{j}(:,i);
            y_abs = H_local*agents{j}.true_state(:,end) + v;
            y_abs_msg = struct('src',agents{j}.agent_id,'dest',agents{j}.agent_id,...
                        'status',[1 1],'type',"abs",'data',y_abs);
            msgs = {y_abs_msg};
            
            if binornd(1,1-msg_drop_prob)
            baseline_filter.update(y_abs,'abs',agents{j}.agent_id,agents{j}.agent_id);
            end
            
            abs_meas_mat(j,i,1) = y_abs(1);
            abs_meas_mat(j,i,2) = y_abs(2);
        end
        
        % relative position
        for k=randperm(length(agents{j}.meas_connections))
%             if agents{j}.agent_id ~= 5
                v_rel = mvnrnd([0,0],R_rel)';
%                 v_rel = v_rel_data{j}(:,i);
                y_rel = H_rel*[agents{j}.true_state(:,end); ...
                    agents{agents{j}.meas_connections(k)}.true_state(:,end)] + v_rel;
                y_rel_msg = struct('src',agents{j}.agent_id,'dest',agents{j}.meas_connections(k),...
                    'status',[1 1],'type',"rel",'data',y_rel);
                msgs{end+1} = y_rel_msg;
                
                if binornd(1,1-msg_drop_prob)
                baseline_filter.update(y_rel,'rel',agents{j}.agent_id,agents{j}.meas_connections(k));
                end
                
                rel_meas_mat(j,i,1) = y_rel(1);
                rel_meas_mat(j,i,2) = y_rel(2);
%             end
        end

        %% Process the generated measurements locally, determine which to send
        input = u(2*(j-1)+1:2*(j-1)+2,i);
%         input = zeros(2,1);
        outgoing = agents{j}.process_local_measurements(input,msgs);
        
    % plot(input_tvec,ci_time_vec,'x')
%         add outgoing measurements to each agents "inbox"
%         inbox = forward_inbox;
%         forward_inbox = cell(N,1);
        for k=randperm(length(outgoing))
            dest = outgoing{k}.dest;
            inbox{dest,end+1} = outgoing{k};
            all_msgs{end+1} = outgoing{k};
        end
    end
    
    %% All agents now process received measurements, performing implicit and
    % explicit measurement updates
    for j=randperm(length(agents))
%         if j == 16 && i == 107
%             disp('break')
%         end
        forwarding_msgs = agents{j}.process_received_measurements({inbox{j,:}});
        if length(forwarding_msgs) > 1
            for k = 2:length(forwarding_msgs)
                dest = forwarding_msgs{k}.dest;
                forward_inbox{dest,end+1} = forwarding_msgs{k};
            end
        end
    end
    
    for j=randperm(length(agents))
        agents{j}.process_received_measurements({forward_inbox{j,:}});
    end
    
    %% Covariance intersection thresholding and snapshotting
    ci_inbox = cell(N,1);
    inbox_ind = 1;
    % covariance intersection between agents
    ci_trigger_list = zeros(1,length(agents));
    
    for j=randperm(length(agents))
        alpha = ones(4*(length(agents{j}.connections)+1),1);
        
        if ~isempty(agents{j}.gps_connections)
            gps_all_idx = [];
            for gps_ind = 1:length(agents{j}.gps_connections)
                [~,gps_idx] = agents{j}.get_location(agents{j}.gps_connections(gps_ind));
                gps_all_idx = [gps_all_idx, gps_idx];
            end
            alpha(gps_all_idx) = zeros(1,length(gps_all_idx));
        end

        % check trace of cov to determine if CI should be triggered
        if trace(agents{j}.local_filter.P*diag(alpha)) > agents{j}.tau
            agents{j}.ci_trigger_cnt = agents{j}.ci_trigger_cnt + 1;
            agents{j}.ci_trigger_rate = agents{j}.ci_trigger_cnt / (i-1);
            ci_trigger_list(j) = 1;
            ci_trigger_mat(j,i) = 1;
            
            % determine common states and grab snapshot of those common
            % states
            % save snapshot of state estimate and covariance, send to
            % connection inboxes
            x_snap = agents{j}.local_filter.x;
            P_snap = agents{j}.local_filter.P;
            for k=randperm(length(agents{j}.meas_connections))
    
                % compute transforms for platform and connection, and
                % number of intersecting states
                
                [Ta,il_a] = gen_sim_transform(agents{j}.agent_id,agents{j}.connections,...
                    agents{agents{j}.meas_connections(k)}.agent_id,agents{agents{j}.meas_connections(k)}.connections);
                [Tb,il_b] = gen_sim_transform(agents{agents{j}.meas_connections(k)}.agent_id,...
                    agents{agents{j}.meas_connections(k)}.connections,agents{j}.agent_id,agents{j}.connections);

                % transform means and covariances to group common states at
                % beginning of state vector/covariance
                xaT = Ta\x_snap;
                xaTred = xaT(1:il_a);
                PaT = Ta\P_snap*Ta;
                PaTred = PaT(1:il_a,1:il_a);
                
%                 ci_inbox{agents{j}.connections(k)}{end+1} = {x_snap,P_snap,agents{j}.agent_id,agents{j}.connections};
                ci_inbox{agents{j}.meas_connections(k)}{end+1} = {xaTred,PaTred,...
                                                        agents{j}.agent_id,...
                                                        agents{j}.connections,...
                                                        agents{j}.meas_connections,...
                                                        agents{j}.gps_connections,...
                                                        agents{j}.tau};
                
                x_conn_snap = agents{agents{j}.meas_connections(k)}.local_filter.x;
                P_conn_snap = agents{agents{j}.meas_connections(k)}.local_filter.P;
                
                xbT = Tb\x_conn_snap;
                xbTred = xbT(1:il_b);
                PbT = Tb\P_conn_snap*Tb;
                PbTred = PbT(1:il_b,1:il_b);
                
%                 ci_inbox{j}{end+1} = {x_conn_snap,P_conn_snap,agents{j}.connections(k),agents{agents{j}.connections(k)}.connections};
                ci_inbox{j}{end+1} = {xbTred,PbTred,agents{j}.meas_connections(k),...
                        agents{agents{j}.meas_connections(k)}.connections,...
                        agents{agents{j}.meas_connections(k)}.meas_connections,...
                        agents{agents{j}.meas_connections(k)}.gps_connections,...
                        agents{agents{j}.meas_connections(k)}.ci_trigger_rate};
                
                if isempty(agents{agents{j}.connections(k)}.connections)
                    disp('break')
                end
                
%                 disp(ci_inbox{j}{end}{4})
                
            end
        end
    end
    
    %% Acutal covariance intersection performed (w/ conditional updates on full states)
    for j=randperm(length(agents))
        
%         if ((i > 100 && j == 16) && abs(agents{j}.local_filter.x(5) - agents{j}.true_state(1,end)) > 4)
%             disp('break')
%         end
        
%         if i == 106 && j == 16
%             disp('break')
%         end
        
        for k=randperm(length(ci_inbox{j}))
            if ~isempty(ci_inbox{j}{k})
                xa = agents{j}.local_filter.x;
                Pa = agents{j}.local_filter.P;
                a_id = agents{j}.agent_id;
                a_connections = agents{j}.connections;
                a_meas_connections = agents{j}.meas_connections;
                a_gps_connections = agents{j}.gps_connections;
                
                xb = ci_inbox{j}{k}{1};
                Pb = ci_inbox{j}{k}{2};
                b_id = ci_inbox{j}{k}{3};
                b_connections = ci_inbox{j}{k}{4};
                b_meas_connections = ci_inbox{j}{k}{5};
                b_gps_connections = ci_inbox{j}{k}{6};
                b_rate = ci_inbox{j}{k}{7};
                
                % create placeholders for ests, in case gps needs removal
                xa_fuse = xa;
                Pa_fuse = Pa;
                xb_fuse = xb;
                Pb_fuse = Pb;
                
                % generate similarity transform and intersection between
                % direct connections
%                 [Ta,il_a,intera] = gen_sim_transform(agents{j}.agent_id,agents{j}.connections,b_id,b_meas_connections);
%                 [Tb,il_b,interb] = gen_sim_transform(b_id,b_meas_connections,agents{j}.agent_id,agents{j}.connections);
%             
%                 xaT = Ta\xa;
%                 xa_fuse = xaT(1:il_a);
%                 PaT = Ta\Pa*Ta;
%                 Pa_fuse = PaT(1:il_a,1:il_a);
%                 
                % extract direction connection states from ests
                
                % intersect A connections w/ A meas connections
                [Ta_a2a,il_a2a,ia2a] = gen_sim_transform(a_id,a_connections,a_id,a_meas_connections);
                % intersect B connections w/ B meas connections
                [Tb_b2b,il_b2b,ib2b] = gen_sim_transform([],intersect([b_id,b_connections],[a_id,a_connections]),b_id,b_meas_connections);
                
                % transform and extract meas states only
                xaT_tmp = Ta_a2a\xa;
                xa_nogps = xaT_tmp(1:il_a2a);
                PaT_tmp = Ta_a2a\Pa*Ta_a2a;
                Pa_nogps = PaT_tmp(1:il_a2a,1:il_a2a);
                
                xbT_tmp = Tb_b2b\xb;
                xb_nogps = xbT_tmp(1:il_b2b);
                PbT_tmp = Tb_b2b\Pb*Tb_b2b;
                Pb_nogps = PbT_tmp(1:il_b2b,1:il_b2b);
                
                % intersect A and B measure only connections
                [Ta,il_a,intera] = gen_sim_transform([],ia2a,[],ib2b);
                [Tb,il_b,interb] = gen_sim_transform([],ib2b,[],ia2a);
                
                % find intersection of measurement connections in A and B
                xaT_tmp = Ta\xa_nogps;
                xa_fuse = xaT_tmp(1:il_a);
                PaT_tmp = Ta\Pa_nogps*Ta;
                Pa_fuse = PaT_tmp(1:il_a,1:il_a);
                
                xbT_tmp = Tb\xb_nogps;
                xb_fuse = xbT_tmp(1:il_b);
                PbT_tmp = Tb\Pb_nogps*Tb;
                Pb_fuse = PbT_tmp(1:il_b,1:il_b);
                
                [tatmp,ilatmp,interatmp] = gen_sim_transform(a_id,a_connections,[],intera);
                xaT = tatmp\xa;
                PaT = tatmp\Pa*tatmp;
                
                
                
                
                % construct transformation
%                 [Ta,il_a,inter] = gen_sim_transform(agents{j}.agent_id,agents{j}.connections,b_id,b_connections);
                
                
                % remove non-directly connected gps states from a, b ests
%                 if ~isempty(agents{j}.gps_connections)
%                     % find gps states
%                     [~,agent_gps_idx] = agents{j}.get_location(agents{j}.gps_connections);
%                     % get measure states by removing gps from total
%                     agent_meas_idx = setdiff(1:size(xa,1),agent_gps_idx);
%                     xa_fuse = xa(agent_meas_idx);
%                     Pa_fuse = Pa(agent_meas_idx,agent_meas_idx);
%                     
%                     send_gps_loc = find(sort(intersect([b_connections,b_id],[agents{j}.agent_id,agents{j}.connections])) == agents{j}.gps_connections);
%                     send_gps_idx = 4*(send_gps_loc-1)+1:4*(send_gps_loc-1)+4;
%                     send_meas_idx = setdiff(1:size(xb,1),send_gps_idx);
%                     xb_fuse = xb(send_meas_idx);
%                     Pb_fuse = Pb(send_meas_idx,send_meas_idx);
%                 end
                
                
                
%                 Tb = Tb(send_meas_idx,send_meas_idx);

                % transform means and covariances to group common states at
                % beginning of state vector/covariance
%                 if size(xa_fuse,1) ~= size(Ta,1)
%                     break_pnt = 1;
%                 end
%                 
%                 xaT = Ta\xa_fuse;
%                 xaTred = xaT(1:il_a);
%                 PaT = Ta\Pa_fuse*Ta;
%                 PaTred = PaT(1:il_a,1:il_a);
                
%                 if size(xb_fuse,1) ~= size(Tb,1)
%                     break_pnt = 1;
%                 end
%                 
%                 xbT = Tb\xb_fuse;
%                 xbTred = xbT(1:il_b);
%                 PbT = Tb\Pb_fuse*Tb;
%                 PbTred = PbT(1:il_b,1:il_b);
            
                xaTred = xa_fuse;
                PaTred = Pa_fuse;
                xbTred = xb_fuse;
                PbTred = Pb_fuse;

                alpha = ones(size(PaTred,1),1);
                [xc,Pc] = covar_intersect(xaTred,xbTred,PaTred,PbTred,alpha);
                
                % compute information delta for conditional update
                invD = inv(Pc) - inv(PaTred);
                invDd = Pc\xc - PaTred\xaTred;
                
                % conditional gaussian update
                V = inv(inv(PaT) + [invD zeros(size(Pc,1),size(PaT,2)-size(Pc,2)); ...
                    zeros(size(PaT,1)-size(Pc,1),size(Pc,2)) zeros(size(PaT)-size(Pc))]);
                v = V*(PaT\xaT + [invDd; zeros(size(PaT,1)-size(Pc,1),1)]);
                
                % transform back to normal state order
                xa_new = tatmp*v;
                Pa_new = tatmp*V/tatmp;
                
                % if there are extended gps states, we want to clone the
                % more reliable source that can directly measure
%                 if ~isempty(agents{j}.gps_connections)
                             
                xa = xa_new;
                Pa = Pa_new;
                
                % if agent is tracking distant gps states
                if ~isempty(agents{j}.gps_connections)    
                    % clone gps states from sender because we don't trust
                    % ours
                    send_gps_loc = find(sort(intersect([b_connections,b_id],[agents{j}.agent_id,agents{j}.connections])) == agents{j}.gps_connections);
                    [~,agent_gps_idx] = agents{j}.get_location(agents{j}.gps_connections);
                    send_gps_idx = 4*(send_gps_loc-1)+1:4*(send_gps_loc-1)+4;
                    xa(agent_gps_idx) = xb(send_gps_idx);
%                     xa(agent_meas_idx) = xa_fuse;
                    Pa(agent_gps_idx,:) = Pb(send_gps_idx,:);
                    Pa(:,agent_gps_idx) = Pb(:,send_gps_idx);
%                     Pa(agent_meas_idx,agent_meas_idx) = Pa_fuse;
                end
                
                % update local estimates
                agents{j}.local_filter.x = xa;
                agents{j}.local_filter.P = Pa;
                
                % update common estimates
                for ii=randperm(length(agents{j}.common_estimates))
                    if agents{j}.common_estimates{ii}.connection == ci_inbox{j}{k}{3}
%                         conn_loc = inter==agents{j}.common_estimates{ii}.connection;
                        % grab only states present in common estimates from
                        % CI result
                        if size(xc,1) > size(agents{j}.common_estimates{ii}.x,1)
                            
                            % have to move common estimate states to top of
                            % CI result
                            
                            % sim transform: a is CI result, b is comm est
                            a_connections_CI = intersect([agents{j}.agent_id,agents{j}.connections],...
                                                    [b_id,b_connections]);
                            b_connections_CI = [agents{j}.agent_id,...
                                            agents{j}.common_estimates{ii}.connection];
                            
                            [Ta,il_a,inter] = gen_sim_transform([],a_connections_CI,[],b_connections_CI);

                            xcT = Ta\xc;
                            PcT = Ta\Pc*Ta;

                            agents{j}.common_estimates{ii}.x = xcT(1:il_a);
                            agents{j}.common_estimates{ii}.P = PcT(1:il_a,1:il_a);
                        
                        else
                            agents{j}.common_estimates{ii}.x = xc;
                            agents{j}.common_estimates{ii}.P = Pc;
                        end
                        
                        agents{j}.connection_tau_rates(ii) = b_rate;
                    end
                end
                
                % update CI threshold tau
%                 agents{j}.tau = min(agents{j}.tau_goal,agents{j}.tau + ...
%                     agents{j}.epsilon_1*sum(agents{j}.connection_taus-agents{j}.tau*ones(length(agents{j}.connection_taus),1)) + ...
%                     agents{j}.epsilon_2*(agents{j}.tau_goal-agents{j}.tau));
                
            end
        end
        
        if use_adaptive
            agents{j}.tau = min(agents{j}.tau_goal,agents{j}.tau + ...
                        agents{j}.epsilon_1*sum(-agents{j}.connection_tau_rates+agents{j}.ci_trigger_rate*ones(length(agents{j}.connection_tau_rates),1)) + ...
                        agents{j}.epsilon_2*(agents{j}.tau_goal-agents{j}.tau));
        end
    end

    %% Update state history of each agent (for plotting)
    for j=1:length(agents)
        agents{j}.local_filter.state_history(:,i) = agents{j}.local_filter.x;
        agents{j}.local_filter.cov_history(:,:,i) = agents{j}.local_filter.P;
        agents{j}.tau_history(i) = agents{j}.tau;
        
        for k=1:length(agents{j}.common_estimates)
            agents{j}.common_estimates{k}.state_history(:,i) = agents{j}.common_estimates{k}.x;
            agents{j}.common_estimates{k}.cov_history(:,:,i) = agents{j}.common_estimates{k}.P;
        end
        
        [loc,iidx] = agents{j}.get_location(agents{j}.agent_id);
%         network_mse(j,i,idx1) = sum((agents{j}.local_filter.state_history(iidx,i) - agents{j}.true_state(:,i)).^2,1)./4;
        network_mse(j,i,idx2) = norm(agents{j}.local_filter.state_history(iidx([1 3]),i) - agents{j}.true_state([1 3],i))^2;
        network_mse_xpos(j,i,idx2) = norm(agents{j}.local_filter.state_history(iidx(1),i) - agents{j}.true_state(1,i))^2;
        network_mse_ypos(j,i,idx2) = norm(agents{j}.local_filter.state_history(iidx(3),i) - agents{j}.true_state(3,i))^2;
        
        baseline_mse(j,i,idx2) = norm(baseline_filter.state_history([4*(j-1)+1,4*(j-1)+3],i) - agents{j}.true_state([1 3],i))^2;
%         network_mse_xpos(j,i,idx3) = norm(agents{j}.local_filter.state_history(iidx(1),i) - agents{j}.true_state(1,i))^2;
%         network_mse_ypos(j,i,idx3) = norm(agents{j}.local_filter.state_history(iidx(3),i) - agents{j}.true_state(3,i))^2;
        
    end
              
%     toc


end

avg_mse(idx3,:) = squeeze(mean(network_mse(:,:,idx3),1));
avg_xmse(idx3,:) = squeeze(mean(network_mse_xpos(:,:,idx3),1));
avg_ymse(idx3,:) = squeeze(mean(network_mse_ypos(:,:,idx3),1));

%% compute costs and FOMs

% compute average covariance trace
% est_err_vec = zeros(1,N);
covar_mean_vec = zeros(1,N);
for jj=1:length(agents)
%     err_vec = zeros(1,size(agents{jj}.local_filter.state_history,2));
    trace_vec = zeros(1,size(agents{jj}.local_filter.cov_history,3));
    for kk=1:size(agents{jj}.local_filter.cov_history,3)
        trace_vec(kk) = trace(agents{jj}.local_filter.cov_history(:,:,kk));
    end
    covar_mean_vec(jj) = mean(trace_vec);
end
% est_err_avg = mean(est_err_vec);
covar_avg = mean(covar_mean_vec);

% compute total and average data transfer

%  dim1=src agent, dim2=dest agent, dim3=meas type, dim4=element [x or y]
comms_mat_sent = zeros(N,N,2,2);
comms_mat_total = zeros(N,N,2,2);
for jj=1:length(all_msgs)
    msg = all_msgs{jj};
    
    type = msg.type=="rel";
    
    for kk=1:length(msg.status)
        comms_mat_total(msg.src,msg.dest,type+1,kk) = comms_mat_total(msg.src,msg.dest,type+1,kk) + 1;
        if msg.status(kk)
            comms_mat_sent(msg.src,msg.dest,type+1,kk) = comms_mat_sent(msg.src,msg.dest,type+1,kk) + 1;
        end
    end  
end

ci_trigger_vec = zeros(1,N);
usage_vec_ci = zeros(1,N);

for jj=1:length(agents)
    ci_trigger_vec(1,jj) = agents{jj}.ci_trigger_cnt;
%     usage_vec_ci(1,i) = agents{i}.ci_trigger_cnt * (size(agents{i}.local_filter.x,1)^2 + size(agents{i}.local_filter.x,1)) * length(agents{i}.connections);
    usage_vec_ci(1,jj) = agents{jj}.ci_trigger_cnt * (72) * length(agents{jj}.connections);
end

usage_vec_msg = sum(comms_mat_sent(:,:,1,1),2)' + sum(comms_mat_sent(:,:,1,2),2)' + sum(comms_mat_sent(:,:,2,1),2)' + sum(comms_mat_sent(:,:,1,2),2)';
usage_vec = usage_vec_ci + usage_vec_msg;

data_trans_avg = mean(usage_vec);

% compute cost fxn
cost_val = w1*(covar_avg/max(covar_mean_vec)) + w2*(data_trans_avg/max(usage_vec));

% compute estimation error average
err_vec = zeros(1,N);
for jj=1:length(agents)
    
    % get location
    [loc,iidx] = agents{jj}.get_location(agents{jj}.agent_id);
    % compute average est err per agent
    err_vec(jj) = mean(mean((agents{jj}.local_filter.state_history(iidx,:) - agents{jj}.true_state(:,:)),2));
end
est_err = mean(err_vec);

for jj=1:length(agents)
    [loc,iidx] = agents{jj}.get_location(agents{jj}.agent_id);
    err_vec(jj) = mean(sqrt(sum((agents{jj}.local_filter.state_history(iidx,:) - agents{jj}.true_state(:,:)).^2,2)./length(input_tvec)));
end
est_rmse = mean(err_vec);

cost(loop_cnt,:) = [loop_cnt delta tau_state_goal covar_avg msg_drop_prob data_trans_avg cost_val est_err est_rmse];

loop_cnt = loop_cnt + 1;
% cost(idx,3) = covar_avg;
% cost(idx,4) = data_trans_avg;
% cost(idx,5) = cost_val;

end
end
end
