select
    t1.*,
    t2.name,
    t2.id,
    case
        when t1.id = 1 then 1
        else 0
    end
        as flag,
    t2.key
from
    table1 t1
    inner join table2 t2
        on t1.id = t2.id
        and t1.name = t2.name
    left join (
        select distinct id from table3
    ) t3
        on t2.id = t3.id
where 1=1
    and t1.surname in (
        'asd',
        'sdf',
        'dfg'
    )
    and t1.title <> 'qwe'
    and t1.date = '5999-01-01'