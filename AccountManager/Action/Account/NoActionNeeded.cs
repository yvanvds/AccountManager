using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Account
{
    public class NoActionNeeded : AccountAction
    {
        public NoActionNeeded() : base(
            "Geen Actie Nodig", "Dit account voldoet aan alle regels.", false)
        {
        }

        public override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            throw new NotImplementedException();
        }
    }
}
