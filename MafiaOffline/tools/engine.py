"""Точный порт игровой логики из lib/ на Python для нагрузочного тестирования.
Портированы: GameEngine.resolveNight/assignRoles, GameState.checkWinner/voteLeaders,
HostController фазы, _handleRegister, renamePlayer, targets-фильтрация."""
import random

MAFIA,DON,DOCTOR,COM,PROS,MANIAC,CIV='mafia','don','doctor','commissioner','prostitute','maniac','civilian'
# Маньяк — мирный житель: голосует днём и заинтересован в победе над мафией.
SIDE={MAFIA:'mafia',DON:'mafia',DOCTOR:'civ',COM:'civ',PROS:'civ',CIV:'civ',MANIAC:'solo'}
NIGHT_ACTIVE={MAFIA,DON,DOCTOR,COM,PROS,MANIAC}
WAITING,NIGHT,DAY,VOTING,ENDED='waiting','night','day','voting','ended'
COLORS=['#FF5733','#33FF57','#3357FF','#FF33A1','#FFD733','#33FFF5','#F533FF','#F5A623',
        '#7ED321','#4A90E2','#E94E77','#50E3C2','#B8E986','#BD10E0','#F8E71C','#9013FE',
        '#417505','#D0021B','#8B572A','#00BCD4']

class Player:
    def __init__(s,pid,name,color):
        s.id,s.name,s.color=pid,name,color
        s.role=None; s.alive=True; s.connected=True; s.role_ack=False
        s.elim_round=None; s.elim_reason=None

class Game:
    """Порт HostController + GameState."""
    def __init__(s,name,planned,setup,seed=0):
        s.name,s.planned,s.setup=name,planned,dict(setup)
        s.rnd=random.Random(seed)
        s.players=[]; s.phase=WAITING; s.round=0; s.time_left=0; s.paused=False
        s.night_actions={}; s.votes={}; s.runoff=[]; s.pending_night=None
        s.awaiting_vote_confirm=False; s.last_healed=None; s.log=[]; s.winner=None
        s.sounds=[]; s.errors=[]

    # ---------- выборки ----------
    @property
    def alive(s): return [p for p in s.players if p.alive]
    def by_id(s,pid): return next((p for p in s.players if p.id==pid),None)
    def name_of(s,pid):
        p=s.by_id(pid); return p.name if p else '—'
    @property
    def night_active(s): return [p for p in s.players if p.alive and p.role in NIGHT_ACTIVE]
    @property
    def mafia_team(s): return [p for p in s.players if p.alive and p.role in (MAFIA,DON)]
    def _first(s,role): return next((p for p in s.players if p.alive and p.role==role),None)
    @property
    def pending_actors(s): return [p for p in s.night_active if p.id not in s.night_actions]
    @property
    def pending_voters(s): return [p for p in s.alive if p.id not in s.votes]

    # ---------- регистрация (порт _handleRegister) ----------
    def register(s,raw_name):
        name=(raw_name or '').strip() or 'Игрок'
        ex=next((p for p in s.players if p.name.lower()==name.lower()),None)
        if ex:
            if ex.connected: return ('DENY','name_taken')
            ex.connected=True
            return ('RECLAIM',ex.id)
        if s.phase!=WAITING: return ('DENY','game_started')
        if len(s.players)>=20: return ('DENY','game_full')
        used={p.color for p in s.players}
        color=next((c for c in COLORS if c not in used),COLORS[len(s.players)%len(COLORS)])
        p=Player(f'p{len(s.players)}',name,color); s.players.append(p)
        return ('OK',p.id)

    def rename(s,pid,new):
        new=(new or '').strip()
        if not new: return 'Имя не может быть пустым'
        if len(new)>20: return 'Имя длиннее 20 символов'
        t=s.by_id(pid)
        if not t: return 'Игрок не найден'
        if t.name==new: return None
        if any(p.id!=pid and p.name.lower()==new.lower() for p in s.players):
            return 'Такое имя уже занято'
        t.name=new; return None

    # ---------- раздача ролей (порт GameEngine.assignRoles) ----------
    def start_game(s):
        pool=[]
        for t in [DON,MAFIA,DOCTOR,COM,PROS,MANIAC]:
            pool += [t]*s.setup.get(t,0)
        n=len(s.players)
        while len(pool)>n: pool.pop()
        # защита баланса: мафия не больше половины ИТОГОВОГО состава
        mc=lambda: sum(1 for r in pool if r in (MAFIA,DON))
        while pool and n - mc() <= 1:
            if MAFIA in pool: idx=len(pool)-1-pool[::-1].index(MAFIA)
            elif DON in pool: idx=len(pool)-1-pool[::-1].index(DON)
            else: break
            pool[idx]=CIV
        while len(pool)<n: pool.append(CIV)
        for i in range(len(pool)-1,0,-1):
            j=s.rnd.randint(0,i); pool[i],pool[j]=pool[j],pool[i]
        for p,r in zip(s.players,pool): p.role=r
        s.sounds.append('roles_dealt')
        s.start_night()

    # ---------- фазы ----------
    def start_night(s):
        s.phase=NIGHT; s.round+=1
        s.night_actions={}; s.votes={}; s.runoff=[]
        s.awaiting_vote_confirm=False; s.paused=False; s.pending_night=None
        s.time_left=20+10*len(s.night_active)
        s.log.append(f'Ночь {s.round}')
        s.sounds.append('night_falls')

    def targets_for(s,p):
        """Порт _targetsFor — что видит игрок в списке целей."""
        c=[x for x in s.alive]
        if s.phase==NIGHT:
            if p.role in (MAFIA,DON): c=[x for x in c if x.role not in (MAFIA,DON)]
            if p.role in (PROS,COM):  c=[x for x in c if x.id!=p.id]
            if p.role==DOCTOR and s.last_healed: c=[x for x in c if x.id!=s.last_healed]
        elif s.phase==VOTING:
            c=[x for x in c if x.id!=p.id]
            if s.runoff: c=[x for x in c if x.id in s.runoff]
        return c

    def night_action(s,pid,target):
        if s.phase!=NIGHT: return 'wrong_phase'
        p=s.by_id(pid)
        if not p or not p.alive: return 'dead'
        if p.role not in NIGHT_ACTIVE: return 'not_active'
        if pid in s.night_actions: return 'already'
        s.night_actions[pid]=target
        if not s.pending_actors: s.finish_night()
        return None

    def resolve_mafia_target(s):
        team=s.mafia_team
        if not team: return None
        don=s._first(DON)
        if don and don.id in s.night_actions and s.night_actions[don.id]:
            return s.night_actions[don.id]
        tally={}
        for m in team:
            t=s.night_actions.get(m.id)
            if t: tally[t]=tally.get(t,0)+1
        if not tally: return None
        mx=max(tally.values())
        leaders=[k for k,v in tally.items() if v==mx]
        return leaders[s.rnd.randrange(len(leaders))]

    def finish_night(s):
        if s.phase!=NIGHT or s.pending_night is not None: return
        a=s.night_actions
        pros=s._first(PROS); blocked=a.get(pros.id) if pros else None
        blk=lambda p: p is not None and p.id==blocked

        doc=s._first(DOCTOR); healed=None
        if doc and not blk(doc):
            t=a.get(doc.id)
            if t is not None and t!=s.last_healed: healed=t

        team=s.mafia_team; mafia_t=None
        team_blocked=bool(team) and all(m.id==blocked for m in team)
        if team and not team_blocked: mafia_t=s.resolve_mafia_target()

        man=s._first(MANIAC); man_t=a.get(man.id) if (man and not blk(man)) else None

        com=s._first(COM); checked=None; is_maf=None
        if com and not blk(com):
            checked=a.get(com.id)
            if checked is not None:
                tp=s.by_id(checked); is_maf=(tp.role==MAFIA) if tp else None

        killed=[]
        if mafia_t is not None and mafia_t!=healed: killed.append(mafia_t)
        if man_t is not None and man_t!=healed and man_t not in killed: killed.append(man_t)
        s.pending_night=dict(killed=killed,mafia=mafia_t,maniac=man_t,healed=healed,
                             blocked=blocked,checked=checked,is_mafia=is_maf)
        s.paused=True

    def announce_night(s):
        o=s.pending_night
        if not o: return
        for pid in o['killed']:
            p=s.by_id(pid)
            if p: p.alive=False; p.elim_round=s.round; p.elim_reason='killed'
        s.last_healed=o['healed']; s.pending_night=None
        s.sounds.append('kill' if o['killed'] else 'no_deaths')
        s.log.append(f"Ночь {s.round}: " + (', '.join(s.name_of(k) for k in o['killed']) if o['killed'] else 'без жертв'))
        if s.check_game_over(): return
        s.start_day()

    def start_day(s):
        s.phase=DAY; s.paused=False; s.votes={}; s.runoff=[]
        s.awaiting_vote_confirm=False
        s.time_left=min(45*len(s.alive),600)
        s.log.append(f'День {s.round}'); s.sounds.append('day_breaks')

    def start_voting(s,candidates=None):
        s.phase=VOTING; s.votes={}; s.runoff=candidates or []
        s.awaiting_vote_confirm=False; s.paused=False
        s.time_left=(20+4*len(s.alive)) if not s.runoff else (15+3*len(s.alive))
        s.sounds.append('vote_start')

    def vote(s,voter_id,target):
        if s.phase!=VOTING: return 'wrong_phase'
        v=s.by_id(voter_id)
        if not v or not v.alive: return 'dead'
        if voter_id in s.votes: return 'already'
        if s.runoff and target is not None and target not in s.runoff: target=None
        s.votes[voter_id]=target
        if not s.pending_voters: s.close_voting()
        return None

    def close_voting(s):
        if s.phase!=VOTING or s.awaiting_vote_confirm: return
        s.paused=True; s.awaiting_vote_confirm=True

    @property
    def vote_tally(s):
        t={}
        for _,c in s.votes.items():
            if c: t[c]=t.get(c,0)+1
        return t
    @property
    def vote_leaders(s):
        t=s.vote_tally
        if not t: return []
        mx=max(t.values()); return [k for k,v in t.items() if v==mx]

    def confirm_elimination(s,pid):
        if pid is None:
            s.log.append('Никто не выбывает'); s.start_night(); return
        p=s.by_id(pid)
        if p: p.alive=False; p.elim_round=s.round; p.elim_reason='voted'
        s.log.append(f'День {s.round}: выбыл {s.name_of(pid)}')
        s.sounds.append('eliminated')
        if s.check_game_over(): return
        s.start_night()

    # ---------- победа ----------
    def check_winner(s):
        """Классические условия победы (v1.1.0).

        Маньяк — одиночка: побеждает, оставшись один. Мафия побеждает при
        равенстве с городом, а не только когда против неё один игрок."""
        al = s.alive
        if not al: return 'nobody'
        m = sum(1 for p in al if SIDE[p.role] == 'mafia')
        k = sum(1 for p in al if SIDE[p.role] == 'solo')
        civ = len(al) - m - k
        if k > 0 and m == 0 and civ == 0: return 'maniac'
        if m == 0 and k == 0: return 'civilians'
        if m > 0 and m >= civ: return 'mafia'
        return None

    def check_game_over(s):
        w=s.check_winner()
        if w is None: return False
        s.phase=ENDED; s.winner=w; s.paused=True
        s.log.append(f'Победа: {w}')
        s.sounds.append({'mafia':'win_mafia','maniac':'win_maniac'}.get(w,'win_civilians'))
        return True
