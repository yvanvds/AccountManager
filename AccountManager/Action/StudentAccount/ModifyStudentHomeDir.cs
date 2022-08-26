using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class ModifyStudentHomeDir : AccountAction
    {
        public ModifyStudentHomeDir() : base(
            "Wijzig de Homedirectory van deze leerling",
            "De Homedirectory bestaat niet of is niet correct", true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            bool connected = await State.App.Instance.AD.Connect().ConfigureAwait(false);
            if (!connected) return;

            await linkedAccount.Directory.Account.SetHome().ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Directory.Account.HasCorrectHome())
            {
                account.Directory.FlagWarning();
                account.Actions.Add(new ModifyStudentHomeDir());
                account.OK = false;
            }
        }
    }
}
