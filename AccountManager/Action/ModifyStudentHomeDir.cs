using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class ModifyStudentHomeDir : AccountAction
    {
        public ModifyStudentHomeDir() : base(AccountActionType.ModifyStudentHomeDir,
            "Wijzig de Homedirectory van deze leerling",
            "De Homedirectory bestaat niet of is niet correct", true, true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await linkedAccount.directoryAccount.SetHome();
        }

        public static void ApplyIfNeeded(LinkedAccount account)
        {
            if (!account.directoryAccount.HasCorrectHome())
            {
                account.DirectoryStatusIcon = "AlertCircleOutline";
                account.DirectoryStatusColor = "Orange";
                account.Actions.Add(new ModifyStudentHomeDir());
                account.AccountOK = false;
            }
        }
    }
}
