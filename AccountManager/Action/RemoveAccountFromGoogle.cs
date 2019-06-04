using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    public class RemoveAccountFromGoogle : AccountAction
    {
        public RemoveAccountFromGoogle() : base(
            "Verwijder Google Account", 
            "Dit account bestaat enkel bij Google. Waarschijnlijk mag dit verwijderd worden.", 
            true)
        {
        }

        public override Task Apply(LinkedAccount linkedAccount)
        {
            throw new NotImplementedException();
        }
    }
}
